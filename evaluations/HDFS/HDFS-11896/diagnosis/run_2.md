I've fully traced the failure path. Here is the root cause.

## Root cause

**`DatanodeDescriptor.resetBlocks()` fails to reset `otherUsed`, while it resets every other capacity field.**

`/bug/source/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeDescriptor.java:313-326`
```java
public void resetBlocks() {
    setCapacity(0);
    setRemaining(0);
    setBlockPoolUsed(0);
    setDfsUsed(0);
    setXceiverCount(0);
    ...            // <-- no setOtherUsed(0)
}
```

This asymmetry is the whole bug. Because `HeartbeatManager.Stats.add`/`subtract` treat `otherUsed` identically to `dfsUsed`, the metric could only diverge for `otherUsed` alone if the underlying field values diverged — and `resetBlocks()` is exactly where they diverge.

## The exact failure path (branches, in order)

**1. Node declared dead.** `HeartbeatManager.heartbeatCheck` finds it dead (`dm.isDatanodeDead(d)`, line 296) → `removeDeadDatanode` → `DatanodeManager.removeDatanode(DatanodeDescriptor)` at `DatanodeManager.java:543`. Two calls run, **in this order**:
- `heartbeatManager.removeDatanode(node)` (line 545) → `stats.subtract(node)` (`HeartbeatManager.java:426`) correctly removes the node's live `otherUsed` (`other1`) and sets `isAlive=false`. Stats contribution for this node is now **0**; node field still `other1`.
- `blockManager.removeBlocksAssociatedTo(node)` (line 546) → `node.resetBlocks()` (`BlockManager.java:1124`). This zeros `dfsUsed`, `capacity`, `remaining`, `blockPoolUsed` on the descriptor **but leaves `otherUsed = other1` (stale)**.

State after death: `dfsUsed=0, capacity=0, otherUsed=other1`.

**2. Node re-registers.** `DatanodeManager.registerDatanode` takes the branch `nodeS != null && nodeN == nodeS` — "node restarted" (`DatanodeManager.java:886-893`) — and calls `heartbeatManager.register(nodeS)` (line 934).

`HeartbeatManager.register` (line 189): condition **`if (!d.isAlive)` is true** → `addDatanode(d)` then `updateHeartbeatState(EMPTY_ARRAY)`:
- `addDatanode` → `stats.add(node)` (`HeartbeatManager.java:407`): line 408 `capacityUsed += node.getDfsUsed()` reads **0** (harmless); line **409 `capacityUsedOther += node.getOtherUsed()` reads the stale `other1`** — this injects a phantom `other1` into the cluster metric.
- `updateHeartbeatState(EMPTY_ARRAY, …)` (line 194): with zero reports the `for` loop is skipped, so `totalOtherUsed=0` and **line 436 `setOtherUsed(0)`** clears the node field. Now node has `otherUsed=0` but `stats.capacityUsedOther` still carries the phantom `other1`.

**3. First real heartbeat** → `DatanodeManager.handleHeartbeat` (line 1347) → `HeartbeatManager.updateHeartbeat` (line 217): `stats.subtract(node)` reads the current `otherUsed=0` (line 426, subtracts nothing), then `stats.add(node)` adds the new `other2`. The phantom `other1` is **never** subtracted.

Because every heartbeat thereafter is a delta update (`subtract` current, `add` new), the phantom offset persists forever — no error is logged.

## Net accounting for this node's `capacityUsedOther`

| step | otherUsed (correct) | dfsUsed (correct) |
|---|---|---|
| death: `subtract` | `0` | `0` |
| death: `resetBlocks` | still `0` in stats, node stale `other1` | `0` |
| register: `stats.add` | **`+other1`** (stale) | `+0` |
| register: `setOtherUsed(0)` | stats keeps `other1` | keeps `0` |
| next HB: subtract 0, add new | `other1 + other2` ❌ | `dfs2` ✓ |

Final `getOtherUsedSpace()` = `datanodeStatistics.getCapacityUsedOther()` (`FSNamesystem.java:6866`) is inflated by exactly one returning node's worth (`other1`) — matching the observed ~3 MB vs. true ~2 MB in the two-DataNode cluster, while capacity and DFS-used stay correct because `resetBlocks()` zeroed those fields before the stale `add`.

The log confirms the sequence: `removeDeadDatanode: lost heartbeat from 127.0.0.1:44383` (line 4315) → `remove datanode 127.0.0.1:44383` (line 4461) → `registerDatanode: node restarted.` (line 4468) → the empty-report re-registration heartbeat `pruneStorageMap … storages reported in heartbeat=0` (line 4473).

**Fix locus (not applied):** the missing `setOtherUsed(0)` in `resetBlocks()` — the single line whose absence dictates this path.
