# HBase-3403 — ground truth (answer key; never shown to the diagnosis LLM)

Derived from `private/fix.diff` (trunk fix commit `0d31ac5f37a2e8866884bb216a3485eea652a822`,
pre-fix `dddee0d50ff77c93a2b39f408bf11f60e397ebf4`). Anonymized names are as they appear in
`source/` — see `private/anonymization_map.json`.

---

## 1. The root-causing line(s) — what the fix changed

**Real:** `src/main/java/org/apache/hadoop/hbase/catalog/MetaEditor.java`,
method `offlineParentInMeta(CatalogTracker, HRegionInfo parent, HRegionInfo a, HRegionInfo b)`,
pre-fix lines **80–83** (identical line numbers in the anonymized `CatalogWriter.java`).

**Anonymized:** `source/src/main/java/org/apache/hadoop/hbase/catalog/CatalogWriter.java`,
method `offlineSplitParent(...)`.

The split commit writes the parent's catalog row with its location **blanked out**:

```java
Put put = new Put(copyOfParent.getRegionName());
addRegionInfo(put, copyOfParent);
put.add(HConstants.CATALOG_FAMILY, HConstants.SERVER_QUALIFIER,      // <-- deleted by the fix
    HConstants.EMPTY_BYTE_ARRAY);                                     // <-- deleted by the fix
put.add(HConstants.CATALOG_FAMILY, HConstants.STARTCODE_QUALIFIER,   // <-- deleted by the fix
    HConstants.EMPTY_BYTE_ARRAY);                                     // <-- deleted by the fix
put.add(HConstants.CATALOG_FAMILY, HConstants.SPLITA_QUALIFIER, Writables.getBytes(a));
put.add(HConstants.CATALOG_FAMILY, HConstants.SPLITB_QUALIFIER, Writables.getBytes(b));
```

The fix is exactly the deletion of those four lines (the two `put.add` calls): the offlined
split parent keeps the `server`/`serverstartcode` of the region server that performed the
split.

## 2. The exact branch/condition that dictates the failure path

**Real:** `src/main/java/org/apache/hadoop/hbase/catalog/MetaReader.java`,
`getServerUserRegions(CatalogTracker, HServerInfo hsi)`, pre-fix line **578**
(same line number in the anonymized `CatalogScanner.java`).
**Anonymized:** `CatalogScanner.getRegionsOfServer(...)`.

```java
Pair<HRegionInfo, HServerInfo> pair = metaRowToRegionPairWithInfo(result);
if (pair == null) continue;
if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {   // <-- the deciding branch
  continue;                                                         //     parent has no server
}                                                                   //     => skipped
hris.put(pair.getFirst(), result);
```

Because §1 blanked `SERVER_QUALIFIER`/`STARTCODE_QUALIFIER`, `pair.getSecond()` is `null` for
the offlined parent, the `continue` is taken, and the parent is **absent** from the set of
regions the crashed server was carrying.

**Consequence — the branch that is therefore never reached:**
`src/main/java/org/apache/hadoop/hbase/master/handler/ServerShutdownHandler.java`
(anonymized `LostServerHandler.java`):

- `process()` iterates only over the `hris` map returned above (pre-fix lines 151–157), so the
  parent's row is never passed to `processDeadRegion`;
- `processDeadRegion(...)` pre-fix line **179** (same line in the anonymized `LostServerHandler.java`):
  ```java
  if (hri.isOffline() && hri.isSplit()) {         // <-- never evaluated for the parent
    fixupDaughters(result, assignmentManager, catalogTracker);
    return false;
  }
  ```
  (anonymized: `processLostRegion` / `recoverSplitChildren`);
- so `fixupDaughters` → `fixupDaughter` (anonymized `recoverSplitChild`) never runs, the
  daughter that missed its catalog row is never re-added and never assigned, and its directory
  is left on HDFS with no catalog row and no server — the observed inconsistency.

## 3. Secondary hunks in the same fix commit (hardening / test hooks, **not** the root cause)

Naming these is neither required nor sufficient for a PASS:

| File | Change | Why it is not the root cause |
|---|---|---|
| `ServerShutdownHandler.fixupDaughter` | replaced the `MetaReader.getRegion` presence probe with `isDaughterMissing` + `IsDaughterVisitor` (a `.META.` scan from the daughter's row) | handles Todd Lipcon's review case where the daughter has itself already split; the daughter would still never be examined without §1 |
| `MetaReader.fullScan(…, startrow)` | new overload | support for the visitor above |
| `CatalogJanitor.setEnabled` / `HMaster.setCatalogJanitorEnabled` | new switch | test hook so the janitor cannot remove the parent mid-test |
| `TestSplitTransactionOnCluster` | new test | the fix's regression test |

## 4. Grading bar (§8: exact line **and** exact branch, no partial credit)

A run **PASSes** only if it states **both**:

- **(a) the root-causing line** — that `CatalogWriter.offlineSplitParent` (real
  `MetaEditor.offlineParentInMeta`) writes `SERVER_QUALIFIER` / `STARTCODE_QUALIFIER` as
  `EMPTY_BYTE_ARRAY` into the split parent's catalog row, and that this write is what must go;
  **and**
- **(b) the exact branch** — the server-match filter in `CatalogScanner.getRegionsOfServer`
  (real `MetaReader.getServerUserRegions`), `pair.getSecond() == null || !pair.getSecond().equals(hsi)`
  → `continue`, which drops the offlined parent from the crashed server's region set, so that
  `LostServerHandler.processLostRegion`'s `hri.isOffline() && hri.isSplit()` branch never runs
  for it and `recoverSplitChildren` is never invoked.

Naming only the missing daughter, only the fixup path, or only "the parent row has no server"
without tying it to the `offlineSplitParent` write is a **FAIL**. Identifying (a) but not (b),
or (b) but not (a), is a **FAIL**. A secondary tally of "named the root-causing line (a) only"
is recorded in `summary.md` for comparison with the other bugs in this study, but the headline
`successes/5` uses the two-part bar above.
