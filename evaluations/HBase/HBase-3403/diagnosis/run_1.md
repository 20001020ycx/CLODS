## Root cause

The failure is not a symptom of hbck itself — it faithfully reports that daughter region `ac6a4798d6ab5e1826f038e6a5567a16` exists on disk but has neither a `.META.` row nor a live serving RS. The state was created by the master's failover for RS `57cf6f9ce629,43789,1786933864882`, which was aborted moments after committing a split; only one of the two new daughters was re-hosted.

### Timeline established from the log

1. Parent region split completes on RS 43789:
   - `CatalogWriter.offlineSplitParent` (catalog row of `usertable,,1786933877432.598e5e2...` gets `server=EMPTY`, `SPLITA=ac6a…`, `SPLITB=fa1b…`) — line `10008965 19:09:45,475`.
   - `CatalogWriter.addSplitChild` for both daughters, both logged with `serverInfo=57cf6f9ce629,43789,1786933864882` — lines `10084300` (fa1b) and `10087547` (ac6a).
2. RS 43789 is aborted 0.7 s later — `10163866 19:09:46,576 MiniHBaseCluster: Aborting serverName=57cf6f9ce629,43789...` / `10165489 FATAL ... Aborting for tests`.
3. Master runs `LostServerHandler` for the dead server:
   - `10474876 19:10:00,909 LostServerHandler: Re-hosting 1 region(s) last served by 57cf6f9ce629,43789,1786933864882 (0 already mid-transition, left alone)`.
   - Only fa1b is assigned to RS 45403 (`10484619 ... Assigning region usertable,mye,...fa1b... to 57cf6f9ce629,45403,1786933864811`), then its META row is refreshed by PostOpenDeployTasks (`10572343 ... Refreshed catalog row usertable,mye,...fa1b...`).
   - Daughter ac6a is never mentioned again until fsck runs at 19:31.
4. Hbck runs at 19:31, `listStatus` on `.../usertable/ac6a4798...` — line `11331131` — then emits the error at `11334381`.

### Exact code and branches that produce the failure

Failure reporting — `HBaseFsck.doConsistencyCheck`:

- `source/src/main/java/org/apache/hadoop/hbase/util/HBaseFsck.java:420-422`
  ```java
  } else if (!inMeta && inHdfs && !isDeployed) {
    errors.reportError("Region " + descriptiveName +
      " has a directory on HDFS with no catalog row, " +
      "and no region server is serving it.");
  ```
  The three booleans are set at lines 381–384. For ac6a:
  - `inMeta == false` because `getMetaEntries` (HBaseFsck.java:683-752) never inserts an HbckInfo whose `metaEntry` is set for encoded name `ac6a4798...` — the META scan doesn't return an `ac6a` row at all (see below).
  - `inHdfs == true` because `checkHdfs` (HBaseFsck.java:239-294) walks the table directory (line 269-292) and creates a fresh HbckInfo for the hex-named region dir found on HDFS (line 275: `getOrCreateInfo(encodedName)`), setting `foundRegionDir`.
  - `isDeployed == false` because `processRegionServers` (HBaseFsck.java:324-358, uses `getOnlineRegions`) is asked by every live RS and none of them reports ac6a — nobody has been told to open it.

Why the META row / assignment for ac6a is missing — the recovery path in `LostServerHandler.process`:

- `source/src/main/java/org/apache/hadoop/hbase/master/handler/LostServerHandler.java:122-135` — the handler scans META for regions belonging to the dead server:
  ```java
  hris = CatalogScanner.getRegionsOfServer(this.server.getCatalogTracker(), this.hsi);
  ```
- `CatalogScanner.getRegionsOfServer` at `source/src/main/java/org/apache/hadoop/hbase/catalog/CatalogScanner.java:562-588` iterates every META row and filters:
  ```java
  if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {
    continue;
  }
  hris.put(pair.getFirst(), result);
  ```
  Only rows whose `info:server` column equals the dead server survive.
- `LostServerHandler.process` at lines 151-157 then reassigns each surviving row:
  ```java
  for (Map.Entry<HRegionInfo, Result> e: hris.entrySet()) {
    if (processLostRegion(...)) {
      this.services.getAssignmentManager().assign(e.getKey(), true);
    }
  }
  ```

The scan on this run returns two rows (`next 1 / next 1 / next 0` RPC log, lines 10458638-10465133): the offlined **parent** row (server=EMPTY → filtered by `pair.getSecond() == null`) and **daughter B (fa1b)** (server=43789 → matches, assigned). Daughter A (ac6a) is not in the returned set, so `hris.size() == 1` — precisely what the master logs as "Re-hosting 1 region(s)". Ac6a is never reassigned; consequently `postOpenDeployTasks → CatalogWriter.addSplitChild(...)` never runs for it (HRegionServer.java:1352-1358), and its META row is never (re)written.

Why the "safety net" that exists for exactly this case never fires:

- `LostServerHandler.processLostRegion` at LostServerHandler.java:172-186:
  ```java
  if (hri.isOffline() && hri.isSplit()) {
    LOG.debug("Region ... is an out-of-service split parent; verifying its children are recorded");
    recoverSplitChildren(result, assignmentManager, catalogTracker);
    return false;
  }
  ```
  is designed to walk the parent's SPLITA/SPLITB columns via `recoverSplitChildren` → `recoverSplitChild` (LostServerHandler.java:194-226), and `CatalogWriter.addSplitChild(catalogTracker, hri, null); assignmentManager.assign(hri, true)` (lines 220-222) for any daughter absent from META.
- But this branch is only reached for rows in `hris`. The parent 598e5e is **not** in `hris` because `CatalogWriter.offlineSplitParent` set its server column to `EMPTY_BYTE_ARRAY`:
  - `source/src/main/java/org/apache/hadoop/hbase/catalog/CatalogWriter.java:80-83`
    ```java
    put.add(HConstants.CATALOG_FAMILY, HConstants.SERVER_QUALIFIER,
        HConstants.EMPTY_BYTE_ARRAY);
    put.add(HConstants.CATALOG_FAMILY, HConstants.STARTCODE_QUALIFIER,
        HConstants.EMPTY_BYTE_ARRAY);
    ```
  causing `metaRowToRegionPairWithInfo` (CatalogScanner.java:377-395) to return `pair.getSecond() == null` for the parent, which trips the `continue` at CatalogScanner.java:578-579 in `getRegionsOfServer`.

So the concrete failure path is:

1. RS 43789 aborts mid-way through publishing/opening the two just-created split daughters.
2. `LostServerHandler.process` calls `CatalogScanner.getRegionsOfServer(...)` which — because `offlineSplitParent` zeros the parent's `info:server`/`info:startcode` (CatalogWriter.java:80-83) — filters the parent out at CatalogScanner.java:578-579 and returns only the surviving daughter rows (fa1b).
3. The reassignment loop in LostServerHandler.java:151-157 therefore only assigns fa1b. Ac6a, whose META row is missing/unmatched, is never reassigned, and the "recoverSplitChildren" repair path (LostServerHandler.java:179-184, 209-226) — the only mechanism that would put ac6a back into META and schedule its assignment — is never invoked, precisely because it is guarded by `hri.isOffline() && hri.isSplit()` on a parent row that has been filtered out of the recovery list.
4. Twenty‑one minutes later, hbck falls into the `!inMeta && inHdfs && !isDeployed` branch at HBaseFsck.java:420-422 for encoded name `ac6a4798d6ab5e1826f038e6a5567a16`, producing the reported error.
