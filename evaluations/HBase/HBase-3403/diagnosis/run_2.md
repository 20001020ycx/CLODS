Based on my analysis of the log and the source, here is the root cause:

## Timeline (from `symptom.log`)
- `19:09:45,475` — RS `57cf6f9ce629,43789,1786933864882` (which is hosting `-ROOT-` plus parent `598e5e2f…`) offlines the split parent in META (`CatalogWriter: Took split parent … out of service in the catalog`). Per `CatalogWriter.offlineSplitParent` this sets `info:server = EMPTY_BYTE_ARRAY` and `info:serverstartcode = EMPTY_BYTE_ARRAY` on the parent row, with SPLITA=`ac6a4798…` and SPLITB=`fa1b6637…`.
- `19:09:45,856` / `19:09:45,863` — daughter openers each successfully `CatalogWriter.addSplitChild(...)` — both daughters' META rows written with `server=57cf6f9ce629:43789`.
- `19:09:45,877` — master receives `REGION_SPLIT` and (via `AssignmentManager.handleSplitReport`) marks both daughters online on 43789 in **in‑memory** state only.
- `19:09:46,583` — RS 43789 is force‑aborted (`FATAL … Aborting for tests`).
- `19:09:53,167` — `ServerManager: Added=57cf6f9ce629,43789,1786933864882 to dead servers … root=true, meta=false` → a `MetaLostServerHandler` (subclass of `LostServerHandler`) is submitted.
- `19:10:00,909` — the handler logs: **`Re-hosting 1 region(s) last served by 57cf6f9ce629,43789,1786933864882 (0 already mid‑transition, left alone)`**, and only `fa1b6637…` is re‑assigned to 45403. `ac6a4798…` is never re‑assigned.
- `19:31:05,674` — `hbck` lists `/user/root/usertable/ac6a4798…`, finds no matching META row → the reported `ERROR: Region … has a directory on HDFS with no catalog row …`.

So the failure is: after a split, the RS that hosted the parent + one/both daughters aborts; the master's shutdown handler recovers only **one** daughter (`fa1b6637`) and leaves the other (`ac6a4798`) orphaned on HDFS.

## Where the code goes wrong

The master's per‑server recovery works only from what a META scan returns:

`source/src/main/java/org/apache/hadoop/hbase/master/handler/LostServerHandler.java:125`
```java
hris = CatalogScanner.getRegionsOfServer(this.server.getCatalogTracker(), this.hsi);
```

Regions are then re‑assigned only from that `hris`:

`LostServerHandler.java:151-157`
```java
for (Map.Entry<HRegionInfo, Result> e: hris.entrySet()) {
  if (processLostRegion(e.getKey(), e.getValue(), …)) {
    this.services.getAssignmentManager().assign(e.getKey(), true);
  }
}
```

`getRegionsOfServer` **filters out any META row whose `info:server` is null/empty**:

`source/src/main/java/org/apache/hadoop/hbase/catalog/CatalogScanner.java:573-582`
```java
while((result = metaServer.next(scannerid)) != null) {
  …
  Pair<HRegionInfo,HServerInfo> pair = metaRowToRegionPairWithInfo(result);
  if (pair == null) continue;
  if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {
    continue;           // <-- parent row dropped here
  }
  hris.put(pair.getFirst(), result);
}
```

and `metaRowToRegionPairWithInfo` produces `(hri, null)` exactly when the row has no `SERVER_QUALIFIER` bytes:

`CatalogScanner.java:383-394`
```java
final byte[] value = data.getValue(HConstants.CATALOG_FAMILY, HConstants.SERVER_QUALIFIER);
if (value != null && value.length > 0) {
  … return new Pair<>(info, hsi);
} else {
  return new Pair<>(info, null);   // <-- parent falls here
}
```

The parent's `info:server` was deliberately blanked by:

`source/src/main/java/org/apache/hadoop/hbase/catalog/CatalogWriter.java:80-83`
```java
put.add(CATALOG_FAMILY, SERVER_QUALIFIER,     EMPTY_BYTE_ARRAY);
put.add(CATALOG_FAMILY, STARTCODE_QUALIFIER, EMPTY_BYTE_ARRAY);
```

So the **parent row is never included in `hris`**. This matters because the master's only "did the split leave a hole?" safety net lives inside `processLostRegion`, and it is only reachable *for a row that made it into `hris`*:

`LostServerHandler.java:172-186`
```java
public static boolean processLostRegion(HRegionInfo hri, Result result, …) {
  …
  if (hri.isOffline() && hri.isSplit()) {                         // <-- split parent branch
    LOG.debug("Region " + … + " is an out-of-service split parent; verifying its children are recorded");
    recoverSplitChildren(result, assignmentManager, catalogTracker);
    return false;
  }
  return true;
}
```

`recoverSplitChildren` (`LostServerHandler.java:194-226`) is the piece that reads `SPLITA_QUALIFIER`/`SPLITB_QUALIFIER` from the parent row and, for any daughter not already present in META, calls `CatalogWriter.addSplitChild(...)` + `assignmentManager.assign(hri, true)` to bring it back:

```java
Pair<HRegionInfo,HServerAddress> pair =
    CatalogScanner.getRegion(catalogTracker, hri.getRegionName());
if (pair == null || pair.getFirst() == null) {
  LOG.info("Repairing; unrecorded split child " + hri.getEncodedName());
  CatalogWriter.addSplitChild(catalogTracker, hri, null);
  assignmentManager.assign(hri, true);
}
```

Because the parent row is filtered out at `CatalogScanner.java:578`, the `hri.isOffline() && hri.isSplit()` branch at `LostServerHandler.java:179` never fires, so `recoverSplitChildren` never runs. Nothing else in the recovery path ever consults the parent's `splitA`/`splitB` columns.

## Why this loses `ac6a4798` in this run

The compactor thread that ran `SplitTransaction.execute` (`SplitTransaction.java:189-286`) launches both daughters in parallel `DaughterOpener` threads (`SplitTransaction.java:266-275`). Each daughter's `postOpenDeployTasks` (`HRegionServer.java:1352-1357`) does the daughter's META write:
```java
if (daughter) {
  CatalogWriter.addSplitChild(ct, r.getRegionInfo(), getServerInfo());
}
```
The RS aborts almost immediately after (`19:09:46,583 FATAL … Aborting for tests`). The daughter B (`fa1b6637`) put reached META on RS 45403 and stuck; the daughter A (`ac6a4798`) put did not survive on META (`hbck` at 19:31 confirms `ac6a4798` has no META row while `fa1b6637` still does). Under a correct design, the master's shutdown handler would have caught this via the parent's SPLITA reference — but as shown above, the parent row is filtered out of `getRegionsOfServer`, so the fix‑up path (`recoverSplitChildren` → `recoverSplitChild` → `addSplitChild` + `assign`) is unreachable.

Master log confirms the exact branch that ran:
```
19:10:00,909 LostServerHandler: Re-hosting 1 region(s) last served by 57cf6f9ce629,43789,1786933864882 (0 already mid-transition, left alone)
19:10:00,909 Creating (or updating) unassigned node for fa1b663732df891192c59f2e5d85c434 with OFFLINE state
```
No `Repairing; unrecorded split child …` line ever appears (i.e., `recoverSplitChild` at `LostServerHandler.java:220` never executed), because `processLostRegion`'s split‑parent branch (`LostServerHandler.java:179`) was never entered.

## Root cause, precisely

- **Failing decision:** `CatalogScanner.getRegionsOfServer` at `CatalogScanner.java:578` — the `pair.getSecond() == null || !pair.getSecond().equals(hsi)` branch drops the split parent row (whose `info:server` was zeroed by `CatalogWriter.offlineSplitParent` at `CatalogWriter.java:80-83`).
- **Consequence:** the parent never reaches `LostServerHandler.processLostRegion` at `LostServerHandler.java:172`, so its `if (hri.isOffline() && hri.isSplit())` branch at line 179 is not taken, so `recoverSplitChildren` (line 194) never runs on the dead server's parent.
- **Effect:** when an RS aborts in the small window right after a split (parent already offlined in META, daughter‑A META put lost due to the abort), the master's per‑server recovery in `LostServerHandler.process` (line 92) only sees the surviving daughter row (`fa1b6637`) and re‑assigns it. Daughter A (`ac6a4798`) has an on‑disk region directory but no META row and no server serving it — which is exactly what `HBaseFsck.java:421-422` prints:

```
ERROR: Region … has a directory on HDFS with no catalog row, and no region server is serving it.
```
