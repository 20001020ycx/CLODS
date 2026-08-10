# Ground truth — HDFS-11896 (PRIVATE, never shown to the diagnosis LLM)

Real bug: **HDFS-11896** "Non-dfsUsed will be doubled on dead node re-registration"
(branch-2.7 pre-fix `b51623503fb`). Derived from `private/fix.diff`.
The failure path is transcribed 1:1 into the anonymized `source/`
(`com.acme.cluster.usage`); line numbers below refer to the anonymized tree.
The identifier mapping is in `private/anonymization_map.json`.

## The failure path (how the doubling happens)
`ClusterState.getAuxUsedSpace()` → `LivenessTracker.getAuxUsedTotal()` returns the
incrementally-maintained `Stats.auxUsedTotal`, kept by `Stats.add`/`Stats.subtract`
(`auxUsedTotal += / -= node.getAuxUsed()`).

1. Node live and heartbeating → `auxUsedTotal` includes its `auxUsed` (= 5000).
2. Node expires → `NodeRegistry.removeExpiredNode` → `LivenessTracker.dropNode`
   (`stats.subtract`, `auxUsedTotal -= 5000`) → `ShardManager.releaseNodeShards` →
   **`NodeUsageRecord.clearNodeState()`**.
3. Node re-registers → `NodeRegistry.registerNode` → **`LivenessTracker.register`**.
4. Next real heartbeat → `LivenessTracker.onHeartbeat` (subtract-then-add).

## Root-causing line(s) — BOTH must be named
### (1) `NodeUsageRecord.clearNodeState()` omits resetting `auxUsed`
File `NodeUsageRecord.java`, lines **54–60** (anonymized).
```java
public void clearNodeState() {
  setCapacity(0);
  setRemaining(0);
  setPoolUsed(0);
  setPrimaryUsed(0);
  setXceiverCount(0);
  // BUG: setAuxUsed(0) is MISSING
}
```
It zeroes every node-level total **except `auxUsed`**. So after a node is removed,
its `NodeUsageRecord` still carries the stale `auxUsed` (5000).
(Real: `DatanodeDescriptor.resetBlocks()` zeroes capacity/remaining/blockPoolUsed/
dfsUsed/xceiverCount but not `nonDfsUsed`.)

### (2) `LivenessTracker.register()` adds the node to the totals BEFORE resetting it
File `LivenessTracker.java`, lines **24–31** (anonymized).
```java
synchronized void register(final NodeUsageRecord d) {
  if (!d.alive) {                                      // <-- the branch
    addNode(d);                                        // stats.add(d): auxUsedTotal += d.getAuxUsed()  (STALE 5000)
    d.applyUsageReport(UsageReport.EMPTY_ARRAY, 0L, 0L, 0);  // only NOW is d.auxUsed reset to 0
  }
}
```
`addNode(d)` (line 33-35) calls `stats.add(d)` → `auxUsedTotal += node.getAuxUsed()`
(`Stats.add`, line 69) using the **stale** `auxUsed` left by `clearNodeState()`,
and only *afterwards* does `applyUsageReport(EMPTY)` zero `d.auxUsed`. The stale
5000 is now baked into `auxUsedTotal` and is never subtracted (the next heartbeat's
`stats.subtract` sees `auxUsed == 0`). The subsequent real heartbeat then adds the
true 5000 on top → the node's auxUsed is counted **twice** → 15000 instead of 10000.
(Real: `HeartbeatManager.register()` calls `addDatanode(d)` — which does
`stats.add(d)` — before `updateHeartbeatState(EMPTY)`.)

## Exact wrong branch / condition
The decisive branch is `if (!d.alive)` in `LivenessTracker.register` (line 25): on
the re-registration path it runs `addNode(d)` (stats.add of the **stale, un-reset**
`auxUsed`) *before* `applyUsageReport` clears it. Combined with `clearNodeState()`
never resetting `auxUsed`, the removed node's stale auxiliary-used value is
re-added on re-registration and double-counted.

## What a correct diagnosis must name (PASS criteria)
1. `NodeUsageRecord.clearNodeState()` fails to reset `auxUsed` (it resets the other
   totals but not `auxUsed`), leaving a stale value on a removed node — **and**
2. On re-registration, `LivenessTracker.register()` adds the node's (stale) usage to
   the cluster total (`addNode`→`stats.add`, `auxUsedTotal += getAuxUsed()`) **before**
   `applyUsageReport(EMPTY)` resets it (the ordering / the `if(!d.alive)` re-register
   branch), so the stale `auxUsed` is counted again and never subtracted → doubled.

A run naming only the symptom site (`getAuxUsedSpace`/`Stats`) or only one of the two
without the stale-`auxUsed`-re-added-on-reregistration mechanism = FAIL.

## The real fix (either location resolves it; both verified on `source/`)
- (A) reset `auxUsed` in `clearNodeState()` (add `setAuxUsed(0)`), i.e. real fix:
  `resetBlocks()` → recompute all totals incl. `nonDfsUsed`; **or**
- (B) reorder `register()` so `applyUsageReport(EMPTY)` runs **before** `addNode`
  (real branch-2.7 fix to `HeartbeatManager.register`).
Both were verified against the anonymized `source/`: each returns the metric to 10000.
