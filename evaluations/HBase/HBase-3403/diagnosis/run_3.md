Based on the log evidence and source-code walk, here's the root cause.

## Timeline (region `ac6a…` = daughter A of `598e5e…`)

| Time | Event | Source line |
|---|---|---|
| 19:09:45,418 | `splits/ac6a…` renamed to `usertable/ac6a…` (daughter HDFS dir created) | `SplitTransaction.createDaughterRegion`/`moveInitialFilesIntoPlace` |
| 19:09:45,475 | Parent offlined in `.META.`: `Took split parent …598e5e… out of service` | `CatalogWriter.offlineSplitParent` (CatalogWriter.java:72–91) |
| 19:09:45,863 | `Recorded split child …ac6a…, serverInfo=…,43789,…` | `postOpenDeployTasks` → `CatalogWriter.addSplitChild` (HRegionServer.java:1352–1354; CatalogWriter.java:93–106) |
| 19:09:46,583 | `FATAL … ABORTING region server …,43789,…: Aborting for tests` | external test kill |
| 19:09:52,991 | RS closes `ac6a…` locally (no META touch) | `CloseRegionHandler` |
| 19:09:53,167 | Master starts recovery for the dead RS | `LostServerHandler.process` |
| 19:10:00,909 | `Re-hosting 1 region(s) last served by …,43789,… (0 already mid-transition, left alone)` — only `fa1b…` is reassigned | `LostServerHandler.process` |
| 19:31:05 | `hbck` sees an on-disk region dir with no matching META row | `HBaseFsck.doConsistencyCheck` |

## The exact failure branch hbck fires

`source/src/main/java/org/apache/hadoop/hbase/util/HBaseFsck.java:420-422`

```java
} else if (!inMeta && inHdfs && !isDeployed) {
    errors.reportError("Region " + descriptiveName +
        " has a directory on HDFS with no catalog row, " +
        "and no region server is serving it.");
}
```

with the booleans computed at `HBaseFsck.java:381-384`:

```java
boolean inMeta   = hbi.metaEntry != null;      // FALSE — MetaScanner (getMetaEntries, line 683–752) found no row
boolean inHdfs   = hbi.foundRegionDir != null; // TRUE  — set in checkHdfs, line 275–276, the renamed splits/ac6a… dir
boolean isDeployed = !hbi.deployedOn.isEmpty();// FALSE — processRegionServers, line 349–351, no live RS reports it
```

The follow-up `ERROR: Consistency check failed for table usertable` comes from `checkIntegrity()` at `HBaseFsck.java:503-506`, because `ac6a…` never contributes an edge to `TInfo` (its `metaEntry` is `null`, filtered at `HBaseFsck.java:484-486`), so `fa1b…`'s key range `["mye",∞)` doesn't cover `[,"mye")` and `TInfo.check()` fails.

## Why hbck sees `!inMeta && !isDeployed` — the design bug in the recovery path

The daughter is orphaned by the interaction of three code sites:

1. **`CatalogWriter.offlineSplitParent`** (`CatalogWriter.java:72–91`) is called *before* the daughters are opened (`SplitTransaction.java:251–254`, prior to `DaughterOpener.start()` at 266–269). It unconditionally *clears* the parent's server columns:

   ```java
   put.add(HConstants.CATALOG_FAMILY, HConstants.SERVER_QUALIFIER, HConstants.EMPTY_BYTE_ARRAY);
   put.add(HConstants.CATALOG_FAMILY, HConstants.STARTCODE_QUALIFIER, HConstants.EMPTY_BYTE_ARRAY);
   ```

2. **`CatalogScanner.getRegionsOfServer`** (`CatalogScanner.java:561–588`) is the *only* thing `LostServerHandler` uses to enumerate the dead RS's regions (called from `LostServerHandler.java:125`). Its filter drops any row whose server column is empty:

   ```java
   Pair<HRegionInfo, HServerInfo> pair = metaRowToRegionPairWithInfo(result);
   if (pair == null) continue;
   if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {   // ← line 578-580
       continue;
   }
   hris.put(pair.getFirst(), result);
   ```

   Combined with step 1, the offlined split parent `598e5e…` — although *physically* still owned by the dead 43789 — is invisible to `getRegionsOfServer`. The log confirms this: `Re-hosting 1 region(s) last served by …,43789,… (0 already mid-transition, left alone)` — only `fa1b…` is in `hris`.

3. **`LostServerHandler.processLostRegion`** (`LostServerHandler.java:172–186`) contains the *only* safety net that would have re-recorded/reassigned a missing daughter:

   ```java
   if (hri.isOffline() && hri.isSplit()) {
       LOG.debug("Region " + hri.getRegionNameAsString() +
           " is an out-of-service split parent; verifying its children are recorded");
       recoverSplitChildren(result, assignmentManager, catalogTracker);
       return false;
   }
   return true;
   ```

   and `recoverSplitChild` (`LostServerHandler.java:209–226`) which repairs the situation:

   ```java
   Pair<HRegionInfo, HServerAddress> pair =
       CatalogScanner.getRegion(catalogTracker, hri.getRegionName());
   if (pair == null || pair.getFirst() == null) {
       LOG.info("Repairing; unrecorded split child " + hri.getEncodedName());
       CatalogWriter.addSplitChild(catalogTracker, hri, null);
       assignmentManager.assign(hri, true);
   } else {
       LOG.debug("Split child " + hri.getRegionNameAsString() + " already recorded");
   }
   ```

   Because of step 2, this branch **is never entered** for our parent, so `recoverSplitChildren` is never called, so `recoverSplitChild` never runs for `ac6a…`, so the "Repairing; unrecorded split child" / follow-up `assign(hri, true)` never fires. The log has neither the "already recorded" debug nor the "Repairing" info line for either daughter, confirming the branch was skipped.

`ac6a…`'s row therefore stays absent from META (nothing ever rewrites it), no RS is told to open it (nothing ever assigns it), and the on-disk directory sits there until the 21-minute-later `hbck` run finds it and reports the ERROR.

## Summary of the guilty branches/conditions

- **Trigger**: `SplitTransaction.execute()` runs `CatalogWriter.offlineSplitParent(…)` at `SplitTransaction.java:252` before the parallel `DaughterOpener` threads (`SplitTransaction.java:266–275`) commit both daughter rows via `postOpenDeployTasks → addSplitChild` (`HRegionServer.java:1352–1354`). The parent's SERVER/STARTCODE columns are wiped to `EMPTY_BYTE_ARRAY` at `CatalogWriter.java:80–83`.
- **RS 43789 aborted "for tests"** before daughter A's META row survives (row is absent by fsck time).
- **Recovery filter** at `CatalogScanner.java:578–580` (`pair.getSecond() == null || !pair.getSecond().equals(hsi) → continue`) hides the split parent from `LostServerHandler`.
- **Recovery bypass**: because the parent isn't in `hris`, the `hri.isOffline() && hri.isSplit()` branch at `LostServerHandler.java:179` — the only path that calls `recoverSplitChildren`/`recoverSplitChild` (LostServerHandler.java:194–226) — never executes, so the missing/unassigned daughter is never repaired.
- **hbck verdict** at `HBaseFsck.java:420–422` (`!inMeta && inHdfs && !isDeployed`) fires, and `checkIntegrity` (`HBaseFsck.java:481–507`) drops the null-`metaEntry` region so the surviving `fa1b…` alone can't cover the table's keyspace, producing `Consistency check failed for table usertable`.
