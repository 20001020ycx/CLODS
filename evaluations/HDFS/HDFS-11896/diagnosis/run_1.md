I have the complete diagnosis, fully corroborated by the log. Here it is.

## Root cause

The cluster-wide **other-used** metric (`FSNamesystem.getOtherUsedSpace` → `HeartbeatManager.getCapacityUsedOther`) is an *incrementally* maintained running total (`Stats.capacityUsedOther`), kept in sync by paired `stats.add(node)` / `stats.subtract(node)` calls that read `node.getOtherUsed()`. The invariant holds only if the per-node `otherUsed` field is properly zeroed between a node's death and its re-registration — **and it is not.**

`DatanodeDescriptor.resetBlocks()` zeroes every per-node storage field **except `otherUsed`**:

`/bug/source/.../blockmanagement/DatanodeDescriptor.java:313`
```java
public void resetBlocks() {
    setCapacity(0);
    setRemaining(0);
    setBlockPoolUsed(0);
    setDfsUsed(0);        // <-- dfsUsed reset...
    setXceiverCount(0);   // ...but NO setOtherUsed(0)
    ...
}
```
That single omission is why *only* other-used drifts while capacity and DFS-used stay correct.

## The exact failure path (branches)

Let the returning node's true other-used be **X** (≈1 MB). Track its contribution **S** to `stats.capacityUsedOther`. Steady state: `S = X`, `node.otherUsed = X`.

**1. Node declared dead** — `HeartbeatManager.heartbeatCheck` takes branch `dead == null && dm.isDatanodeDead(d)` (line 296) → `DatanodeManager.removeDeadDatanode` → `removeDatanode` (line 543):
- `heartbeatManager.removeDatanode` → `if (node.isAlive)` true → `stats.subtract(node)` reads `getOtherUsed()=X` → **S = X − X = 0** (HeartbeatManager.java:426).
- Then `blockManager.removeBlocksAssociatedTo` → `node.resetBlocks()` (BlockManager.java:1124). This zeroes capacity/dfsUsed/etc. **but leaves `node.otherUsed = X`.**

Log confirms: `removeDeadDatanode: lost heartbeat from 127.0.0.1:44383` (line 4315) → `remove datanode 127.0.0.1:44383` (line 4461).

**2. Node re-registers** — `DatanodeManager.registerDatanode` hits the `nodeS != null && nodeN == nodeS` branch → `"node restarted."` (line 891) → reuses the *same* stale `DatanodeDescriptor` → `heartbeatManager.register(nodeS)`.

`HeartbeatManager.register` (line 189), branch `!d.isAlive` true:
- `addDatanode(d)` → `stats.add(d)` reads the **still-stale** `getOtherUsed()=X` → **S = 0 + X = X** (line 409). (For dfsUsed this adds 0, because `resetBlocks` had zeroed it — hence no drift there.)
- Then `d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, …)` → `setOtherUsed(0)` (DatanodeDescriptor.java:436). Now `node.otherUsed = 0`, but **S is still X** — the stat was not corrected.

Log confirms: `node restarted.` (line 4468).

**3. First real heartbeat** — `HeartbeatManager.updateHeartbeat` (line 217):
- `stats.subtract(node)` reads `getOtherUsed()=0` → **S = X − 0 = X** (the subtract removes nothing).
- `node.updateHeartbeat` sets `otherUsed = X` again.
- `stats.add(node)` → **S = X + X = 2X.**

The node now contributes **2X** to the cluster total while its true value is X — an over-count of exactly one node's worth. Every subsequent heartbeat subtracts X and adds X, so it **stays** at 2X (≈3 MB vs. true 2 MB), with no error logged.

## Fix locus (not applied)

The defect is the missing `setOtherUsed(0)` in `DatanodeDescriptor.resetBlocks()` (line 313). Because `resetBlocks` fails to clear `otherUsed`, the re-registration `stats.add` (HeartbeatManager.java:409) re-adds a value that death's `stats.subtract` (line 426) had already removed, and the follow-up `updateHeartbeatState(EMPTY_ARRAY)` (line 436) zeroes the field without reconciling the aggregate — permanently inflating `capacityUsedOther`.
