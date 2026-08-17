## Root cause: `LostServerHandler` has no safety net for split daughters after the parent has been offlined in META

### The incident

Reconstructed from the log (encoded name → region), the split of `usertable,,...598e5e2f...` on RS `57cf6f9ce629,43789,1786933864882` is captured in these lines:

```
19:09:45,475  CatalogWriter: Took split parent 598e5e2f... out of service in the catalog
19:09:45,856  CatalogWriter: Recorded split child usertable,mye,...fa1b663732... serverInfo=57cf6f9ce629,43789,1786933864882
19:09:45,863  CatalogWriter: Recorded split child usertable,,   ...ac6a4798...   serverInfo=57cf6f9ce629,43789,1786933864882
19:09:45,877  ServerManager: Received REGION_SPLIT ...Daughters ac6a4798, fa1b663732 from ...,43789
19:09:46,576  MiniHBaseCluster: Aborting serverName=57cf6f9ce629,43789,...
19:09:52,976  CloseRegionHandler: Processing close of ...ac6a4798   (RS-abort-driven close)
19:09:53,167  LostServerHandler: Recovering write-ahead logs of ...,43789
19:10:00,909  LostServerHandler: Re-hosting 1 region(s) last served by ...,43789 (0 already mid-transition, left alone)
19:10:00,944  AssignmentManager: Assigning region usertable,mye,...fa1b663732 to 57cf6f9ce629,45403,...
19:31:05,674  HDFS listStatus /user/root/usertable/ac6a4798...
19:31:05,688  HBaseFsck: Region ...598e5e2f... is an out-of-service split parent; skipping.
19:31:05      ERROR: Region .../ac6a4798... has a directory on HDFS with no catalog row, and no region server is serving it.
```

Only **one** of the two daughters (`fa1b663732`) was re-hosted; `ac6a4798` was silently dropped and never reassigned.

### The exact branches that produce the failure

1. **`CatalogWriter.offlineSplitParent` clears `info:server` on the parent row** — `source/src/main/java/org/apache/hadoop/hbase/catalog/CatalogWriter.java:78-83`
    ```java
    Put put = new Put(copyOfParent.getRegionName());
    addRegionInfo(put, copyOfParent);
    put.add(CATALOG_FAMILY, SERVER_QUALIFIER,    EMPTY_BYTE_ARRAY);   // ← 80-81
    put.add(CATALOG_FAMILY, STARTCODE_QUALIFIER, EMPTY_BYTE_ARRAY);   // ← 82-83
    ```
    After a successful split the parent row in META has `info:server = <empty>`. This is exactly the state at 19:09:45,475 (log line above).

2. **`CatalogScanner.getRegionsOfServer` filters that row out** — `source/src/main/java/org/apache/hadoop/hbase/catalog/CatalogScanner.java:573-583`
    ```java
    while((result = metaServer.next(scannerid)) != null) {
      ...
      Pair<HRegionInfo, HServerInfo> pair = metaRowToRegionPairWithInfo(result);
      if (pair == null) continue;
      if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {  // ← 578
        continue;
      }
      hris.put(pair.getFirst(), result);
    }
    ```
    `metaRowToRegionPairWithInfo` (lines 383-394) returns `pair.second = null` whenever `info:server` is empty. So the offlined parent is unconditionally skipped by the recovery scan. **The parent never enters `hris`.**

3. **`LostServerHandler.processLostRegion` gates the split-parent recovery behind an `hri` that isn't in `hris`** — `source/src/main/java/org/apache/hadoop/hbase/master/handler/LostServerHandler.java:172-186`
    ```java
    if (hri.isOffline() && hri.isSplit()) {                 // ← 179
      LOG.debug("Region " + hri + " is an out-of-service split parent; ...");
      recoverSplitChildren(result, assignmentManager, catalogTracker);  // ← 182
      return false;
    }
    return true;
    ```
    This is the only code path that reads `info:splitA` / `info:splitB` and repairs daughters. It is called from the `process()` loop at lines 151-157:
    ```java
    for (Map.Entry<HRegionInfo, Result> e: hris.entrySet()) {           // ← 151
      if (processLostRegion(e.getKey(), e.getValue(), ...)) {
        this.services.getAssignmentManager().assign(e.getKey(), true);
      }
    }
    ```
    Because of step (2) the parent is not in `hris`, so `processLostRegion` is never invoked with `isOffline() && isSplit()`, and `recoverSplitChildren` is never called. The daughters have **no independent discovery path**.

4. **The `getRegionsOfServer` scan returned only one daughter** — see log at 19:10:00,909 (`Re-hosting 1 region(s)`) and the subsequent single `Assigning region ...fa1b663732 to ...,45403` at 19:10:00,944. Since only rows whose `info:server` matches the dead server’s `hsi` (`HServerInfo.equals` compares hostname+port+startcode; `HServerInfo.java:210-227, 245-247`) are kept at CatalogScanner.java:578, any daughter row that fails that predicate at scan time — for whatever reason (unflushed put not yet visible to the scanner, row briefly missing/empty from a memstore rollover on the META RS between 19:09:45,863 and 19:10:00,909, etc.) — is silently omitted. No log is emitted for the omission.

5. **Even the fallback path, if it had run, wouldn't repair a "daughter row exists but was missed by the scan"** — `LostServerHandler.java:209-226`
    ```java
    Pair<HRegionInfo, HServerAddress> pair =
      CatalogScanner.getRegion(catalogTracker, hri.getRegionName());
    if (pair == null || pair.getFirst() == null) {                       // ← 219
      LOG.info("Repairing; unrecorded split child " + hri.getEncodedName());
      CatalogWriter.addSplitChild(catalogTracker, hri, null);
      assignmentManager.assign(hri, true);
    } else {
      LOG.debug("Split child " + hri + " already recorded");             // ← 224
    }
    ```
    The else-branch at line 223-225 does nothing. It only repairs when the daughter's META row is entirely absent; it does not verify the daughter is being served, and it does not `assign()`.

6. **Nothing else picks up the slack.** `AssignmentManager.processServerShutdown` returns only regions-in-transition; it does not re-derive dead regions from its in-memory `this.servers`/`this.regions`. The `RS_CLOSE_REGION` handlers running inside the aborting server (`CloseRegionHandler.java:97-137`) do not publish ZK CLOSING/CLOSED transitions when `zk == false` (comment at lines 55-58), so the master learns of dead regions **only** via `LostServerHandler`'s META scan. Once step (3) removes the fallback and step (4) misses one daughter, the daughter is orphaned.

### Result

`ac6a4798` was never reassigned, its META row is missing at fsck time, and its HDFS directory survives. `HBaseFsck.doConsistencyCheck` (`source/src/main/java/org/apache/hadoop/hbase/util/HBaseFsck.java:420-422`) hits the `!inMeta && inHdfs && !isDeployed` branch and emits:

> Region hdfs://…/ac6a4798… has a directory on HDFS with no catalog row, and no region server is serving it.

### The design defect in one sentence

`LostServerHandler` treats the `getRegionsOfServer` META scan as authoritative, but the split-parent fallback that would repair split children (via `info:splitA`/`info:splitB`) is itself gated on the parent being present in that same scan — a precondition that `CatalogWriter.offlineSplitParent` deliberately makes impossible by writing `EMPTY_BYTE_ARRAY` into the parent's `info:server` column. Any daughter that the scan misses between the split and the RS abort is silently orphaned.
