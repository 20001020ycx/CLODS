## Root cause

**Region `ac6a4798` was orphaned because a region-server crash landed between the split completing and the master learning about the daughters, and the master's crash‑recovery scanner cannot see split parents.**

### What the log shows (all events in the primary session at 19:09:xx)

1. `SplitTransaction` on RS `57cf6f9ce629,43789,1786933864882` splits parent `598e5e2f…` into daughters `ac6a4798…` (A) and `fa1b6637…` (B):
   - 19:09:45,475 – `CatalogWriter: Took split parent … out of service in the catalog` (parent's SERVER/STARTCODE columns set to `EMPTY_BYTE_ARRAY`, SPLITA/SPLITB set to daughter blobs — `CatalogWriter.offlineSplitParent`, source/…/CatalogWriter.java:80‑87).
   - 19:09:45,849 – both daughters onlined on 43789 (`Onlined usertable,,…ac6a4798…`, `Onlined usertable,mye,…fa1b6637…`).
   - 19:09:45,856 / 45,863 – `Recorded split child …` for **fa1b6637** then **ac6a4798** (`CatalogWriter.addSplitChild`, source/…/CatalogWriter.java:101‑105).
   - 19:09:45,863 – `Region split, META updated, and report to master. …Split took 0sec` and 19:09:45,877 – master receives `REGION_SPLIT` (`ServerManager.regionServerReport` → `AssignmentManager.handleSplitReport`, source/…/AssignmentManager.java:1724‑1746) which does only in‑memory `regionOffline(parent) / regionOnline(a) / regionOnline(b)`.

2. The RS is then aborted:
   - 19:09:46,576 – `MiniHBaseCluster: Aborting serverName=57cf6f9ce629,43789,1786933864882 …: Aborting for tests` (line 10163866–10165489 in the log; ChaosMonkey/test injection).
   - The abort path (`HRegionServer.run()` finally block at HRegionServer.java:652‑656 → `closeAllRegions(true)`) closes each region with `zk=false`, so `CloseRegionHandler` (source/…/CloseRegionHandler.java:109‑133) skips both `setClosingState` and `setClosedState`; no ZK CLOSING/CLOSED notifications are emitted. Both daughters `Closed` at 19:09:52,991 without any ZK event.

3. The master detects the dead RS via ZK ephemeral expiry and runs `MetaLostServerHandler` (subclass of `LostServerHandler`, source/…/MetaLostServerHandler.java + LostServerHandler.java:92‑160):
   - 19:09:53,167 – `LostServerHandler: Recovering write‑ahead logs of 57cf6f9ce629,43789,…` (splits the HLog; no META rows written).
   - 19:10:00,760 – ROOT re‑assigned (`isCarryingRoot()==true`).
   - 19:10:00,880‑909 – `CatalogScanner.getRegionsOfServer(hsi)` (source/…/CatalogScanner.java:561‑588) scans META looking for rows whose `SERVER_QUALIFIER` matches the dead RS.
   - 19:10:00,909 – **`Re‑hosting 1 region(s) last served by 57cf6f9ce629,43789,1786933864882 (0 already mid‑transition, left alone)`** (LostServerHandler.java:146).
   - 19:10:00,944 – only `fa1b6637` is assigned; `ac6a4798` is never touched again. Hbck at 19:31 reports `has a directory on HDFS with no catalog row` (HBaseFsck.java:420 — the branch `!inMeta && inHdfs && !isDeployed`).

### The exact failing branch

The recovery for a crashed RS whose split-parent is offlined depends on a fallback in `LostServerHandler.processLostRegion` (source/…/LostServerHandler.java:172‑186):

```java
if (hri.isOffline() && hri.isSplit()) {
  LOG.debug("Region " + … + " is an out-of-service split parent; verifying its children are recorded");
  recoverSplitChildren(result, assignmentManager, catalogTracker);   // <-- would re-add ac6a4798
  return false;
}
```

`recoverSplitChildren` / `recoverSplitChild` (LostServerHandler.java:194‑226) reads SPLITA/SPLITB from the parent row and, for any daughter not present in META, calls `CatalogWriter.addSplitChild(…, null)` and `assignmentManager.assign(hri, true)`. That is precisely the safety net that would have re‑instated `ac6a4798`.

**This branch is unreachable.** `processLostRegion` is only invoked from the loop at LostServerHandler.java:151‑157:

```java
for (Map.Entry<HRegionInfo, Result> e: hris.entrySet()) {
  if (processLostRegion(e.getKey(), e.getValue(), …)) {
    this.services.getAssignmentManager().assign(e.getKey(), true);
  }
}
```

and `hris` comes from `CatalogScanner.getRegionsOfServer`, whose filter at CatalogScanner.java:578‑580 drops every row whose server does not equal the dead RS:

```java
if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) {
  continue;
}
```

`metaRowToRegionPairWithInfo` (CatalogScanner.java:377‑395) sets `pair.getSecond() == null` whenever `SERVER_QUALIFIER` is empty — which is exactly what `offlineSplitParent` wrote to the parent row at CatalogWriter.java:80‑83. So the offlined split parent is **always** filtered out of `hris`, and `processLostRegion`'s split‑parent branch never fires.

### Why this fatally combines with the RS abort

In `SplitTransaction.execute` (source/…/SplitTransaction.java:250‑276) there is a documented point‑of‑no‑return between `CatalogWriter.offlineSplitParent(…)` (line 252) and the `DaughterOpener` threads writing each daughter row (line 266‑275, via `postOpenDeployTasks` → `CatalogWriter.addSplitChild`, source/…/HRegionServer.java:1352‑1354). If the RS dies in that window carrying the (freshly created) daughters — as happens here at 19:09:46 — recovery relies on the parent row's SPLITA/SPLITB pointers. But because of the filter above, the master:

- silently drops the parent when scanning META for the dead RS's regions,
- therefore never inspects `SPLITA`/`SPLITB`,
- and re-hosts only the daughter whose META row it happens to find in the scan (`fa1b6637`).

The daughter A row (`usertable,,1786933888544.ac6a4798d6ab5e1826f038e6a5567a16.`) is not found by the scan at 19:10:00 (the `Re-hosting 1 region(s)` log leaves no doubt), and there is no code path that consults the parent row's `SPLITA` blob to notice ac6a4798 exists. The daughter's on-disk directory stays under `/user/root/usertable/ac6a4798…` with `.regioninfo` and its compacted HFile, but with:

- no META row (comment message in HBaseFsck.java:421),
- no assignment (`processServerShutdown` returned zero RIT for this server; the parent is filtered from `hris`; the `recoverSplitChildren` fallback is dead code),

which is exactly the symptom hbck reports:

> ERROR: Region hdfs://…/usertable/ac6a4798d6ab5e1826f038e6a5567a16 has a directory on HDFS with no catalog row, and no region server is serving it.

### Summary of the specific branches that dictate the failure

| # | File:line | Branch / effect |
|---|---|---|
| 1 | CatalogWriter.java:80‑83 (in `offlineSplitParent`) | Parent's `SERVER_QUALIFIER`/`STARTCODE_QUALIFIER` written as `EMPTY_BYTE_ARRAY` |
| 2 | SplitTransaction.java:252‑276 | Point‑of‑no‑return: parent is offlined, then daughter A/B opened by parallel `DaughterOpener` threads that call `postOpenDeployTasks` → `addSplitChild`. RS abort at 19:09:46 hits this window. |
| 3 | HRegionServer.java:652‑656 → CloseRegionHandler.java:109/133 (`if (this.zk) …`) | Abort path closes regions with `zk=false`, so no CLOSING/CLOSED ZK events reach the master — master learns of daughters only via META. |
| 4 | CatalogScanner.java:578‑580 (in `getRegionsOfServer`) | `if (pair.getSecond() == null || !pair.getSecond().equals(hsi)) continue;` filters the offlined split parent out of the recovery set. |
| 5 | LostServerHandler.java:151‑157 → LostServerHandler.java:179‑184 (`if (hri.isOffline() && hri.isSplit())`) | The split‑parent recovery branch, which would call `recoverSplitChildren` and re‑insert `ac6a4798`, is unreachable because of (4). |
| 6 | HBaseFsck.java:420‑422 (`!inMeta && inHdfs && !isDeployed`) | This is the exact branch that emits the observed error message once hbck sees the orphaned HDFS directory with no META row and no serving RS. |

Root cause, in one sentence: after `offlineSplitParent` empties the parent row's server column (CatalogWriter.java:80‑83), the master's dead‑server recovery cannot see the parent anymore (filtered at CatalogScanner.java:578‑580); consequently the `recoverSplitChildren` safety net at LostServerHandler.java:179‑184 is dead code, so when RS 43789 was aborted mid‑split, daughter `ac6a4798` — whose META row was not re‑discovered by the scan at 19:10:00,909 — was left with an HDFS directory but no META entry and no assignment, and hbck fires the branch at HBaseFsck.java:420‑422.
