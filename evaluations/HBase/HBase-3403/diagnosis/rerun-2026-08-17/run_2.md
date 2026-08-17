## Root cause

The `ac6a4798…` directory is an orphan on HDFS because the code path designed to detect and repair exactly this condition — `LostServerHandler.recoverSplitChildren` — is guaranteed by construction to be skipped for the parent whose crash orphaned the daughter. Two independent decisions collude:

### 1. The parent is invisible to `getRegionsOfServer` after `offlineSplitParent`

`CatalogWriter.offlineSplitParent` (`src/main/java/org/apache/hadoop/hbase/catalog/CatalogWriter.java:72-91`) intentionally blanks the parent's server columns before writing the SPLITA/SPLITB pointers:

```java
put.add(HConstants.CATALOG_FAMILY, HConstants.SERVER_QUALIFIER,   HConstants.EMPTY_BYTE_ARRAY);   // line 80-81
put.add(HConstants.CATALOG_FAMILY, HConstants.STARTCODE_QUALIFIER, HConstants.EMPTY_BYTE_ARRAY);  // line 82-83
```

Log at `19:09:45,475`: `Took split parent usertable,,1786933877432.598e5e2f5ffcc76fa29f613c7abea723. out of service in the catalog`.

The dead-server scan then goes through `CatalogScanner.metaRowToRegionPairWithInfo` (`src/main/java/org/apache/hadoop/hbase/catalog/CatalogScanner.java:377-395`) whose SERVER-length branch (line 385) is the deciding condition:

```java
if (value != null && value.length > 0) {      // 385  <-- FALSE for split parent, value.length == 0
    …
    return new Pair<>(info, hsi);
} else {
    return new Pair<>(info, null);             // 393  <-- second element is null
}
```

`CatalogScanner.getRegionsOfServer` (`CatalogScanner.java:561-588`) then unconditionally drops any row whose second element is `null`:

```java
if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {   // line 578
    continue;                                                       // line 579  <-- parent row skipped
}
```

Log at `19:10:00`: `Re-hosting 1 region(s) last served by 57cf6f9ce629,43789,1786933864882 (0 already mid-transition, left alone)` — the parent (`598e5e2f…`) is not among them. Only the sibling `fa1b…` was rehosted, which is why `fa1b` recovered cleanly and only `ac6a` is stranded.

### 2. Skipping the parent means `recoverSplitChildren` never runs

`LostServerHandler.process` (`src/main/java/org/apache/hadoop/hbase/master/handler/LostServerHandler.java:121-157`) iterates only `hris` — the map built by `getRegionsOfServer` — so it never dispatches `processLostRegion` for the parent. `processLostRegion` (line 172-186) has the branch that would fix this:

```java
if (hri.isOffline() && hri.isSplit()) {                             // line 179
    LOG.debug("Region " + hri.getRegionNameAsString() +
        " is an out-of-service split parent; verifying its children are recorded");
    recoverSplitChildren(result, assignmentManager, catalogTracker); // line 182
    return false;
}
```

That call chains into `recoverSplitChild` (lines 209-226), whose repair branch is precisely what should have re-registered the orphaned SPLITA daughter:

```java
Pair<HRegionInfo, HServerAddress> pair =
    CatalogScanner.getRegion(catalogTracker, hri.getRegionName());  // line 217-218
if (pair == null || pair.getFirst() == null) {                       // line 219  <-- would fire for ac6a
    LOG.info("Repairing; unrecorded split child " + hri.getEncodedName());
    CatalogWriter.addSplitChild(catalogTracker, hri, null);          // line 221
    assignmentManager.assign(hri, true);                             // line 222
}
```

Because the parent never enters `processLostRegion`, this branch never fires. No `"Repairing; unrecorded split child"` line appears anywhere in the log — confirming the safety net was silently bypassed. The neighboring `CatalogJanitor` also cannot pick this up: the surviving-master's `CatalogJanitor` chore ran only once at `19:07:50` (`Scanned 0 catalog row(s)…`, before the split) and next appears only on shutdown at `19:31:07,996 (… exiting)`, so `cleanParent` / `removeDaughterFromParent` never observe this parent either.

### 3. Why fsck reports the exact error it does

`HBaseFsck.doConsistencyCheck` (`src/main/java/org/apache/hadoop/hbase/util/HBaseFsck.java:377-425`) computes:

```java
boolean inMeta   = hbi.metaEntry != null;         // 381
boolean inHdfs   = hbi.foundRegionDir != null;    // 382
boolean isDeployed = !hbi.deployedOn.isEmpty();   // 384
```

For `ac6a4798…`:
- `inHdfs = true` — the directory renamed at `19:09:45,418` and never deleted.
- `isDeployed = false` — `processRegionServers` never saw it (nobody ever opened it after RS 43789 aborted; `LostServerHandler` reassigned only `fa1b`).
- `inMeta = false` — its row is not surfaced to `HBaseFsck.getMetaEntries` (`HBaseFsck.java:683-751`). The `Recorded split child … ac6a…` at `19:09:45,863` was the only `CatalogWriter` write for it; the safety net that would have re-issued `addSplitChild` after RS 43789 aborted never ran (§2 above).

The three booleans hit exactly the else-if at `HBaseFsck.java:420-422`:

```java
} else if (!inMeta && inHdfs && !isDeployed) {
  errors.reportError("Region " + descriptiveName +
      " has a directory on HDFS with no catalog row, " +
      "and no region server is serving it.");
```

producing the observed:

```
ERROR: Region hdfs://localhost:35027/user/root/usertable/ac6a4798d6ab5e1826f038e6a5567a16
       has a directory on HDFS with no catalog row, and no region server is serving it.
```

### The failure mechanism in one sentence

`offlineSplitParent` writes zero-length `SERVER`/`STARTCODE` bytes on the parent (`CatalogWriter.java:80-83`); `metaRowToRegionPairWithInfo`'s length-guarded branch (`CatalogScanner.java:385`) then classifies the parent as having no server; `getRegionsOfServer` filters it out (`CatalogScanner.java:578`); `LostServerHandler.process` never dispatches `processLostRegion` for the parent (`LostServerHandler.java:151-157`), so the `hri.isOffline() && hri.isSplit()` branch (`LostServerHandler.java:179`) that calls `recoverSplitChildren` → `recoverSplitChild` never runs; the orphaned SPLITA daughter (`ac6a…`) is never re-registered nor reassigned, and `HBaseFsck.doConsistencyCheck` fires the `!inMeta && inHdfs && !isDeployed` branch (`HBaseFsck.java:420-422`).
