## Root cause

**The failure path is a coverage gap in the master's dead-RS recovery: the only code that can heal an orphaned split daughter (`recoverSplitChildren`) is never reachable because its trigger — seeing the parent row in the dead-server's region list — is filtered out by design one step earlier.**

### Observed timeline for `ac6a4798d6ab5e1826f038e6a5567a16`

1. `19:09:45,475` – Parent `598e5e2f…` offlined in META by `CatalogWriter.offlineSplitParent` — SERVER/STARTCODE qualifiers set to `EMPTY_BYTE_ARRAY`, SPLITA/SPLITB filled with daughter infos (`CatalogWriter.java:80-87`).
2. `19:09:45,849` – Daughter `ac6a4798…` onlined by `DaughterOpener` on RS `43789`; `postOpenDeployTasks(…, true)` calls `CatalogWriter.addSplitChild` (`HRegionServer.java:1354`).
3. `19:09:45,877` – Master receives `REGION_SPLIT` → `AssignmentManager.handleSplitReport` runs `regionOnline(a); regionOnline(b);` (`AssignmentManager.java:1745-1746`). Master now knows in-memory that both daughters are on `43789`.
4. `19:09:52,962` – RS `43789` shuts down. In `closeUserRegions` it calls `closeRegion(hri, abort, false)` with `zk=false` (`HRegionServer.java:1588`); `CloseRegionHandler.process()` therefore skips `setClosingState`/`setClosedState` (`CloseRegionHandler.java:109,133`) — the master gets **no** CLOSED events for the daughters.
5. `19:09:53,167` – Master runs `MetaLostServerHandler` for `43789`.
6. `19:10:00,909` – Master logs `Re-hosting 1 region(s) last served by 57cf6f9ce629,43789,1786933864882 (0 already mid-transition, left alone)` — only daughter `fa1b663…` gets reassigned to `45403`.
7. `19:31:05` – hbck lists `/user/root/usertable/ac6a4798…`, finds no META row → `!inMeta && inHdfs && !isDeployed` branch fires (`HBaseFsck.java:420-422`) → the reported error.

### The branches that dictate the failure

**a. `AssignmentManager.processServerShutdown` throws away the master's in-memory knowledge that `ac6a4798…` was on `43789`.**  
`AssignmentManager.java:1694-1702` — `this.servers.remove(hsi)` and `this.regions.remove(region)` are called for every region on the dead server, but the returned `rits` list only contains regions still in `regionsInTransition`. Since `regionOnline` (line 578-583) had already dropped them from RIT, neither daughter is in `rits`. All in-memory server→region information is now gone; recovery must re-derive everything from META.

**b. `LostServerHandler.process` uses only that META scan to build the re-host list.**  
`LostServerHandler.java:121-135, 151-157`:
```java
hris = CatalogScanner.getRegionsOfServer(this.server.getCatalogTracker(), this.hsi);
…
for (Map.Entry<HRegionInfo, Result> e: hris.entrySet()) {
  if (processLostRegion(...)) {
    this.services.getAssignmentManager().assign(e.getKey(), true);
  }
}
```
Anything not returned by that scan is never reassigned.

**c. `CatalogScanner.getRegionsOfServer` unconditionally filters out the split-parent row.**  
`CatalogScanner.java:576-580`:
```java
Pair<HRegionInfo, HServerInfo> pair = metaRowToRegionPairWithInfo(result);
if (pair == null) continue;
if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {
  continue;
}
```
`metaRowToRegionPairWithInfo` (`CatalogScanner.java:383-394`) treats the SERVER qualifier as "no server" whenever its value length is 0:
```java
final byte[] value = data.getValue(CATALOG_FAMILY, SERVER_QUALIFIER);
if (value != null && value.length > 0) { … }
else { return new Pair<>(info, null); }
```
The parent's `SERVER_QUALIFIER` was set to `EMPTY_BYTE_ARRAY` by `offlineSplitParent`, so `pair.getSecond() == null` — the `continue;` at line 579 drops the parent from `hris`.

**d. Because the parent is dropped, `processLostRegion` never sees it, so the split-parent branch never runs and `recoverSplitChildren` is never called.**  
`LostServerHandler.java:179-184`:
```java
if (hri.isOffline() && hri.isSplit()) {
  LOG.debug("… out-of-service split parent; verifying its children are recorded");
  recoverSplitChildren(result, assignmentManager, catalogTracker);
  return false;
}
```
`recoverSplitChild` (`LostServerHandler.java:209-226`) is the *only* code in the recovery path that reads `info:splitA`/`info:splitB` from the parent row and repairs a missing daughter:
```java
Pair<HRegionInfo, HServerAddress> pair =
  CatalogScanner.getRegion(catalogTracker, hri.getRegionName());
if (pair == null || pair.getFirst() == null) {
  LOG.info("Repairing; unrecorded split child " + hri.getEncodedName());
  CatalogWriter.addSplitChild(catalogTracker, hri, null);
  assignmentManager.assign(hri, true);
}
```
This branch would have re-inserted the missing META row for `ac6a4798…` and assigned it, but it depends on the parent reaching it via `processLostRegion` — which is impossible given (c).

### Why the fsck ERROR is the exact expected outcome

With the parent filtered out and only `fa1b663…` matching `hsi` in the META scan, `hris.size() == 1` (matches the log line "Re-hosting 1 region(s)"). The daughter `ac6a4798…` — closed silently by the RS with `zk=false`, dropped from all in-memory master maps by `processServerShutdown`, and unreachable through the parent — is never reassigned. Its HDFS directory (created by `SplitTransaction`'s `rename …/splits/ac6a4798…` at 19:09:45,418 and populated by the compaction that finished at 19:09:46,865) remains, but nothing in the cluster references it. That is precisely the `!inMeta && inHdfs && !isDeployed` condition at `HBaseFsck.java:420-422` that emits the ERROR text in the symptom.

**Summary of the specific lines/branches that dictate the failure:**
- `HRegionServer.closeUserRegions` @ `HRegionServer.java:1588` — closes user regions with `zk=false` on shutdown.
- `CloseRegionHandler.process` @ `CloseRegionHandler.java:109,133` — no ZK transition, so master never sees a CLOSED event.
- `AssignmentManager.processServerShutdown` @ `AssignmentManager.java:1694-1713` — in-memory server→regions map is discarded, only RIT regions are returned.
- `LostServerHandler.process` @ `LostServerHandler.java:125-126, 151-157` — the re-host set is defined solely by the META scan result.
- `CatalogScanner.metaRowToRegionPairWithInfo` @ `CatalogScanner.java:383-394` and `getRegionsOfServer` @ `CatalogScanner.java:578-580` — filter (`pair.getSecond() == null`) drops the split parent because `offlineSplitParent` wrote a zero-length `info:server` value (`CatalogWriter.java:80-83`).
- `LostServerHandler.processLostRegion` @ `LostServerHandler.java:179-184` and `recoverSplitChild` @ `LostServerHandler.java:209-222` — the only self-healing path for a missing daughter row is gated on the parent surviving that filter, which by construction it cannot; so the daughter is left with an HDFS directory, no META row, and no assignment — the exact state hbck reports.
