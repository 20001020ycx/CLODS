## Root Cause

The bug is a design-level hole in the master's dead-server recovery. When RS `57cf6f9ce629,43789,1786933864882` was aborted by the test harness (`MiniHBaseCluster.abortRegionServer` at 19:09:46.583) 720 ms after finishing the split of parent `598e5e2f…`, daughter A (`ac6a4798…`) was silently dropped by the master, and there is no code path that ever fixes it up.

### The chain of branches that produces the error

1. **Split completes and marks the parent offline.** `SplitTransaction.execute` on RS 43789 calls `CatalogWriter.offlineSplitParent(...)` at `SplitTransaction.java:252`, which at `CatalogWriter.java:80-83` overwrites the parent's `info:server` and `info:serverstartcode` cells with `HConstants.EMPTY_BYTE_ARRAY`:
   ```java
   put.add(CATALOG_FAMILY, SERVER_QUALIFIER,    HConstants.EMPTY_BYTE_ARRAY);
   put.add(CATALOG_FAMILY, STARTCODE_QUALIFIER, HConstants.EMPTY_BYTE_ARRAY);
   ```
   (Log: 19:09:45.475 "Took split parent … out of service in the catalog".)

2. **Daughters are opened and their META rows written from the DYING RS.** `DaughterOpener.run` (`SplitTransaction.java:304-311`) → `openDaughterRegion` (`SplitTransaction.java:322-339`) → `HRegionServer.postOpenDeployTasks` (`HRegionServer.java:1332-1359`) → `CatalogWriter.addSplitChild(ct, hri, getServerInfo())` (`HRegionServer.java:1354`, `CatalogWriter.java:93-106`). Both daughter puts are logged: 19:09:45.856 for B, 19:09:45.863 for A, both with `serverInfo=57cf6f9ce629,43789,1786933864882`. The master is notified only via the in-band REGION_SPLIT message consumed at `ServerManager.java:280-283` → `AssignmentManager.handleSplitReport` (`AssignmentManager.java:1724-1757`), which mutates **only** the in-memory `regions`/`servers` maps (`regionOnline(a, hsi); regionOnline(b, hsi);` at lines 1745-1746) — nothing else durable is ever written for the daughters.

3. **RS 43789 aborts.** `HRegionServer.abort` (`HRegionServer.java:1379-1391`) flips `abortRequested`, and `AssignmentManager.processServerShutdown` erases the RS's in-memory region set on the master side. From here forward, `.META.` is the sole source of truth.

4. **Recovery scan uses only the SERVER cell.** `LostServerHandler.process` (`LostServerHandler.java:91-160`) calls `CatalogScanner.getRegionsOfServer(ct, hsi)` at line 125. Its filter is `CatalogScanner.java:578`:
   ```java
   if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) continue;
   ```
   - The parent row is skipped because its `info:server` was blanked in step 1 (`pair.getSecond() == null`, produced by the empty-check branch of `metaRowToRegionPairWithInfo` at `CatalogScanner.java:385-393`).
   - Daughter B matches and is kept.
   - Daughter A is not returned. This is what the log at 19:10:00.909 records: `Re-hosting 1 region(s) last served by 57cf6f9ce629,43789,1786933864882 (0 already mid-transition, left alone)` (`LostServerHandler.java:146-148`).

5. **The split-orphan repair path is unreachable.** `LostServerHandler.processLostRegion` (`LostServerHandler.java:172-186`) has a dedicated branch for this exact situation:
   ```java
   if (hri.isOffline() && hri.isSplit()) {
     recoverSplitChildren(result, assignmentManager, catalogTracker);
     return false;
   }
   ```
   `recoverSplitChild` (`LostServerHandler.java:209-226`) would notice a daughter that is not in META and repair it via `CatalogWriter.addSplitChild(ct, hri, null)` + `assignmentManager.assign(hri, true)`. But this branch is only entered for rows returned by `getRegionsOfServer`, and the parent row was already filtered out in step 4 for having `SERVER=EMPTY`. The step-1 branch (`offlineSplitParent` writes empty SERVER) and the step-4 branch (`getRegionsOfServer` discards empty SERVER) directly contradict step 5 (repair requires the parent to be in the returned set). The healing code is dead in the very scenario it was written for.

6. **CatalogJanitor is not a factor.** `CatalogJanitor` is a `Chore` with `hbase.catalogjanitor.interval` default 300000 ms (`CatalogJanitor.java:57`). In this log it fires only at 19:07:50 (`initialChore`, over an empty META) and next at 19:31 during shutdown; it neither creates nor repairs any state in the affected window. This is confirmed by the surviving parent row observed by hbck: `Region …598e5e2f… is an out-of-service split parent; skipping` (`HBaseFsck.java:401-404`).

7. **hbck reports the observed error.** `HBaseFsck.check(HbckInfo)` sets, at `HBaseFsck.java:381-393`:
   - `inMeta = hbi.metaEntry != null` → **false** (daughter A never re-appeared in `.META.` — the memstore of `.META.` on RS 45403 was continuously up, was never flushed until 19:31:09.788, and no code path in the source ever wrote back for daughter A after step 2).
   - `inHdfs = hbi.foundRegionDir != null` → **true** (dir `/user/root/usertable/ac6a4798…` still present; see 19:31:05.674 listStatus).
   - `isDeployed = !hbi.deployedOn.isEmpty()` → **false** (no RS reported it via `processRegionServers`, `HBaseFsck.java:349-352`).
   
   The branch at `HBaseFsck.java:420-422` fires verbatim:
   ```java
   } else if (!inMeta && inHdfs && !isDeployed) {
     errors.reportError("Region " + descriptiveName +
       " has a directory on HDFS with no catalog row, and no region server is serving it.");
   }
   ```
   Then `checkIntegrity` (`HBaseFsck.java:481-508`) walks tables and reports `Consistency check failed for table usertable` at `HBaseFsck.java:503-506` because the missing daughter leaves a gap in the key-range edges built at line 499.

### One-line summary

The split protocol writes the two daughter META rows only via best-effort RPCs from the splitting RS (`CatalogWriter.addSplitChild` at `SplitTransaction.java:326` / `HRegionServer.java:1354`) and blanks the parent's `SERVER` cell (`CatalogWriter.java:80-83`); when the RS dies immediately after, `LostServerHandler` discovers regions to re-host solely via the SERVER-cell filter in `CatalogScanner.getRegionsOfServer` (`CatalogScanner.java:578`), and its split-orphan fixup at `LostServerHandler.java:179-183` / `.209-226` is unreachable because that same filter discards the parent — so any daughter whose META row is missing/incomplete at recovery time is silently lost, becoming an HDFS-only orphan that `HBaseFsck` reports via the `!inMeta && inHdfs && !isDeployed` branch at `HBaseFsck.java:420-422`.
