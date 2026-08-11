The log confirms the full path. Here is the root cause.

## Root cause

`DatanodeDescriptor.resetBlocks()` zeroes every per-node utilization field **except `otherUsed`**. Because the cluster `capacityUsedOther` statistic is maintained *incrementally* (subtract-on-death, add-on-register), the leftover stale `otherUsed` value gets **added a second time** when a dead node re-registers, and that extra amount is never subtracted again.

### The exact code and branches

**1. Node declared dead → `otherUsed` is *not* cleared (the defect)**

`removeDeadDatanode` (`DatanodeManager.java:588`) → `removeDatanode` (`DatanodeManager.java:543`) does two things:

- `heartbeatManager.removeDatanode(nodeInfo)` (`DatanodeManager.java:545`) → `stats.subtract(node)` (`HeartbeatManager.java:211`), which at line **426** does `capacityUsedOther -= node.getOtherUsed()`, using the node's last-known value `O`. This correctly removes `O`. Balanced so far.
- `blockManager.removeBlocksAssociatedTo(nodeInfo)` (`DatanodeManager.java:546`) → `node.resetBlocks()` (`BlockManager.java:1124`).

`resetBlocks()` (`DatanodeDescriptor.java:313-326`) resets:
```
setCapacity(0);      // 314
setRemaining(0);     // 315
setBlockPoolUsed(0); // 316
setDfsUsed(0);       // 317
setXceiverCount(0);  // 318
```
It clears `dfsUsed`, `capacity`, `remaining`, `blockPoolUsed` — but there is **no `setOtherUsed(0)`**. So after death the descriptor holds `dfsUsed=0 … otherUsed=O` (still non‑zero).

**2. Node re-registers → the stale `otherUsed` is re-added**

Log line 4468 (`registerDatanode(891)` "node restarted") shows the `nodeS != null && nodeN == nodeS` branch (`DatanodeManager.java:885-893`), which calls `heartbeatManager.register(nodeS)` (`DatanodeManager.java:934`).

`HeartbeatManager.register` (`HeartbeatManager.java:189-196`):
```
if (!d.isAlive) {                 // 190 — true, node was marked dead
  addDatanode(d);                 // 191 → stats.add(d)
  d.updateHeartbeatState(EMPTY_ARRAY, 0L, 0L, 0, 0, null);  // 194
}
```

Crucially, `addDatanode` runs **before** the empty-report reset. `stats.add(d)` (`HeartbeatManager.java:407`) executes:
- line **408** `capacityUsed += node.getDfsUsed()` → adds **0** (was cleared by `resetBlocks`) → correct.
- line **409** `capacityUsedOther += node.getOtherUsed()` → adds **`O`** (was *not* cleared) → **spurious re-add**.

Only *after* that, line 194's `updateHeartbeatState(EMPTY_ARRAY,…)` runs `setOtherUsed(0)` (`DatanodeDescriptor.java:436`, total from empty reports = 0), but the stale `O` has already been baked into `stats.capacityUsedOther`.

**3. It stays wrong forever**

The next real heartbeat (`updateHeartbeat`, `HeartbeatManager.java:217-225`) does `stats.subtract(node)` (subtracts the now-0 `otherUsed`), then `stats.add(node)` adds the fresh `O'`. So the metric becomes `O` (spurious, from step 2) `+ O'` (correct) = one extra node's worth. Nothing ever removes the leftover `O`.

### Why only `otherUsed` is wrong

`dfsUsed`, `capacity`, `remaining`, `blockPoolUsed` are all zeroed by `resetBlocks()` at line 317/314/315/316, so `stats.add` at re-registration adds 0 for them (no double count). Only `otherUsed` is missing from `resetBlocks()`, so only `capacityUsedOther` is inflated — matching the symptom (~3 MB reported vs. ~2 MB true, capacity/DFS-used correct, no exception).

### The single decisive condition

The failure hinges on `resetBlocks()` (`DatanodeDescriptor.java:313`) omitting `otherUsed`, combined with the incremental accounting in `Stats.add/subtract` (`HeartbeatManager.java:409` / `426`) and the ordering in `register()` where `addDatanode` (line 191) reads `getOtherUsed()` **before** the empty-report reset (line 194). If `resetBlocks()` had cleared `otherUsed` like the other four fields, `stats.add` at re-registration would add 0 and the metric would stay correct.
