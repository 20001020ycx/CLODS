# Ground truth — HDFS-11896 (PRIVATE, never shown to the diagnosis LLM)

Real bug: **HDFS-11896** "Non-dfsUsed will be doubled on dead node re-registration"
(branch-2.7 pre-fix `b51623503fb`). Derived from `private/fix.diff`.
`source/` is the **real** HDFS failure-path source with only the metric renamed
`nonDfsUsed → otherUsed` and the JIRA id scrubbed (see `private/anonymization_map.json`).
Line numbers below refer to the files under `source/`.

## The failure path
`FSNamesystem.getOtherUsedSpace()` (`FSNamesystem.java:6866`) →
`DatanodeStatistics.getCapacityUsedOther()` (impl = `HeartbeatManager`) → returns the
incrementally-maintained `HeartbeatManager.Stats.capacityUsedOther`, kept by
`Stats.add`/`Stats.subtract` (`capacityUsedOther += / -= node.getOtherUsed()`,
`HeartbeatManager.java:409` / `:426`).

1. Node live & heartbeating → `capacityUsedOther` includes its `otherUsed` (5000).
2. Node declared dead → `DatanodeManager.removeDeadDatanode` → `removeDatanode(node)` →
   `heartbeatManager.removeDatanode` (`stats.subtract`, `capacityUsedOther -= 5000`) →
   `blockManager.removeBlocksAssociatedTo(node)` → **`DatanodeDescriptor.resetBlocks()`**.
3. Node re-registers → `DatanodeManager.registerDatanode` → `heartbeatManager.register`.
4. Next real heartbeat → `heartbeatManager.updateHeartbeat` (subtract-then-add).

## Root-causing line(s) — BOTH must be named
### (1) `DatanodeDescriptor.resetBlocks()` omits resetting `otherUsed`
`DatanodeDescriptor.java`, lines **313–319**:
```java
public void resetBlocks() {
  setCapacity(0);
  setRemaining(0);
  setBlockPoolUsed(0);
  setDfsUsed(0);
  setXceiverCount(0);
  // BUG: setOtherUsed(0) is MISSING
  ...
}
```
It zeroes every node-level total **except `otherUsed`** (contrast `updateHeartbeatState`,
which does call `setOtherUsed(totalOtherUsed)` at `DatanodeDescriptor.java:436`). So after
a dead node is removed, its `DatanodeDescriptor` still carries the stale `otherUsed` (5000).
(Real term: `nonDfsUsed`; real method omission: `setNonDfsUsed(0)`.)

### (2) `HeartbeatManager.register()` adds the node to the totals BEFORE resetting it
`HeartbeatManager.java`, lines **189–196**:
```java
synchronized void register(final DatanodeDescriptor d) {
  if (!d.isAlive) {                                          // <-- the re-registration branch
    addDatanode(d);                                          // addDatanode -> stats.add(d):
                                                             //   capacityUsedOther += d.getOtherUsed()  (STALE 5000)
    d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, 0L, 0L, 0, 0, null); // only NOW is d.otherUsed reset to 0
  }
}
```
`addDatanode(d)` (`:202-206`) runs `stats.add(d)` → `capacityUsedOther += node.getOtherUsed()`
(`Stats.add`, `:409`) using the **stale** `otherUsed` left by `resetBlocks()`, and only
*afterwards* does `updateHeartbeatState(EMPTY_ARRAY)` zero `d.otherUsed`. The stale 5000 is
now baked into `capacityUsedOther` and is never subtracted (the next heartbeat's
`stats.subtract` sees `otherUsed == 0`). The subsequent real heartbeat then adds the true
5000 on top → the node's other-used is counted **twice** → 15000 instead of 10000.

## Exact wrong branch / condition
The decisive branch is `if (!d.isAlive)` in `HeartbeatManager.register` (`:190`): on the
re-registration path it calls `addDatanode(d)` (which does `stats.add` of the **stale,
un-reset** `otherUsed`) *before* `updateHeartbeatState(EMPTY_ARRAY)` clears it. Combined with
`resetBlocks()` never resetting `otherUsed`, the removed node's stale value is re-added on
re-registration and double-counted.

## What a correct diagnosis must name (PASS criteria)
1. `DatanodeDescriptor.resetBlocks()` fails to reset `otherUsed` (it resets the other
   node-level totals but not `otherUsed`), leaving a stale value on a removed node — **and**
2. On re-registration, `HeartbeatManager.register()` adds the node's (stale) usage to the
   cluster total (`addDatanode` → `stats.add`, `capacityUsedOther += getOtherUsed()`) **before**
   `updateHeartbeatState(EMPTY_ARRAY)` resets it (the ordering / the `if(!d.isAlive)`
   re-registration branch), so the stale `otherUsed` is counted again and never subtracted →
   doubled.

A run naming only the symptom site (`getOtherUsedSpace`/`Stats`) or only one of the two
without the stale-`otherUsed`-re-added-on-reregistration mechanism = FAIL.

## The real fix (either location resolves it)
- (A) reset the metric in `resetBlocks()` — the real upstream fix routes `resetBlocks()`
  through `updateStorageStats(getStorageReports(), 0, 0, 0, 0, null)` so all totals incl.
  `nonDfsUsed`/`otherUsed` are recomputed; **or**
- (B) reorder `HeartbeatManager.register()` so `updateHeartbeatState(EMPTY_ARRAY)` runs
  **before** `addDatanode` (the real branch-2.7 fix to `HeartbeatManager.register`).
Both were verified to restore the metric to 10000.
