I have traced the complete failure path and confirmed it against the log. Here is the root cause.

## Root cause

**`DatanodeDescriptor.resetBlocks()` (`.../blockmanagement/DatanodeDescriptor.java:313`) zeroes every per-node usage field *except* `otherUsed`.**

```java
public void resetBlocks() {
    setCapacity(0);        // 314
    setRemaining(0);       // 315
    setBlockPoolUsed(0);   // 316
    setDfsUsed(0);         // 317
    setXceiverCount(0);    // 318
    ...                    // <-- setOtherUsed(0) is MISSING
}
```

The cluster metric `getOtherUsedSpace()` (`FSNamesystem.java:6866`) returns `HeartbeatManager.Stats.capacityUsedOther`, an **incrementally maintained** counter (add/subtract on every membership/heartbeat change), *not* a value recomputed from the live set. Its correctness depends on one invariant: **`stats.capacityUsedOther` must always equal the sum of `node.getOtherUsed()` over the live nodes.** The missing reset breaks that invariant during a dead → re-register cycle, and once broken it never self-heals.

## The exact failure path (branches, in order)

Two live DNs, each `otherUsed=5000`, `capacity=20000`. Metric = 10000.

**1. Node A declared dead** — `HeartbeatManager.heartbeatCheck` → `removeDeadDatanode` → `DatanodeManager.removeDatanode` (`DatanodeManager.java:543`), which runs two steps *in this order*:
- `heartbeatManager.removeDatanode` — enters the `if (node.isAlive)` branch (`HeartbeatManager.java:210`) → `stats.subtract`: `capacityUsedOther -= node.getOtherUsed()` (line 426) subtracts **5000** → 5000. Sets `isAlive=false`.
- `blockManager.removeBlocksAssociatedTo` (`BlockManager.java:1124`) → `node.resetBlocks()`. Capacity/dfsUsed/etc. are zeroed, **but `A.otherUsed` stays 5000 (stale)**.

State: `capacityUsedOther=5000` (correct), but node A: `capacity=0`, `otherUsed=5000`. ✔ matches `PROBE dead: cluster_otherUsed=5000 ... capacityTotal=20000`.

**2. Node A re-registers** — `registerDatanode` takes the `nodeS != null && nodeN == nodeS` ("node restarted") branch (`DatanodeManager.java:885-893`) → `heartbeatManager.register(nodeS)` (line 934).
`HeartbeatManager.register` (line 189) enters the `if (!d.isAlive)` branch:
- `addDatanode` → `stats.add`: `capacityUsedOther += node.getOtherUsed()` (line 409) re-adds the **stale 5000** → 10000; `capacityTotal += node.getCapacity()` adds **0** (capacity *was* reset).
- `d.updateHeartbeatState(EMPTY_ARRAY, …)` (line 194): with no reports, `setOtherUsed(0)` (`DatanodeDescriptor.java:436`) resets `A.otherUsed=0` **without touching stats**.

State: `capacityUsedOther=10000`, but `A.getOtherUsed()=0` → invariant now violated (stats holds a 5000 contribution the node no longer carries).

**3. First real heartbeat from A** — `handleHeartbeat` → `heartbeatManager.updateHeartbeat` (`HeartbeatManager.java:221-224`), reports `otherUsed=5000` again:
- `stats.subtract(node)`: `capacityUsedOther -= node.getOtherUsed()` subtracts only the reset **0** → 10000 (the orphaned 5000 is never removed).
- `node.updateHeartbeat` → `setOtherUsed(5000)`.
- `stats.add(node)`: `capacityUsedOther += 5000` → **15000**; `capacityTotal += 20000` → 40000.

Final: `otherUsed=15000` (**wrong, +5000**), `capacityTotal=40000` (**correct**). ✔ exactly matches `PROBE rereg: cluster_otherUsed=15000 ... capacityTotal=40000`.

## Why only `otherUsed` is wrong (the diagnostic tell)

`capacityTotal`, `dfsUsed`, `blockPoolUsed` travel the identical add/subtract/register machinery yet stay correct — the log proves it (`capacityTotal=40000`). The *only* difference is step 1: `resetBlocks()` zeroes those fields, so at re-registration `addDatanode` re-adds **0** for them and no orphan is created. It does **not** zero `otherUsed`, so `addDatanode` re-adds the stale **5000**, which `updateHeartbeatState` then strands in `stats`. That single omission is the whole bug; the "storage FAILED / pruneStorageMap" lines in the log are an incidental side effect of the `EMPTY_ARRAY` registration heartbeat and are not part of the miscount.

**Fix locus (root cause):** `DatanodeDescriptor.resetBlocks()` must also reset `otherUsed` (i.e., a missing `setOtherUsed(0)` alongside lines 314-317). No error is logged because nothing throws — only the incrementally-maintained counter is permanently skewed by the orphaned contribution.
