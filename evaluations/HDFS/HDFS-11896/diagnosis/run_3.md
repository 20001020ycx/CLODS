Confirmed. The log shows node `127.0.0.1:44383` declared dead (`removeDeadDatanode`/`removeDatanode` at 19:40:01), then re-registering at 19:40:02 via the "node restarted" (existing-node `nodeS`) path — exactly the sequence that triggers the leak.

## Root cause

The cluster-wide **other-used** metric leaks by one node's worth of `otherUsed` on every dead→re-register cycle because **`DatanodeDescriptor.resetBlocks()` resets every per-node usage field *except* `otherUsed`**, and the re-registration path adds that stale field into the aggregate before it is zeroed.

### The two conditions that combine

**1. The omission in `resetBlocks()`** — `DatanodeDescriptor.resetBlocks()` (`blockmanagement/DatanodeDescriptor.java:313‑326`):

```java
public void resetBlocks() {
    setCapacity(0);
    setRemaining(0);
    setBlockPoolUsed(0);
    setDfsUsed(0);
    setXceiverCount(0);
    ...                 // <-- NO setOtherUsed(0)
}
```

It zeroes `capacity`, `remaining`, `blockPoolUsed`, `dfsUsed`, `xceiverCount` — but never `otherUsed`. `otherUsed` is a plain stored field (`protocol/DatanodeInfo.java:47`, `setOtherUsed` at :284), just like the others, so this is a genuine gap, not a computed value.

**2. The re-registration add-before-reset ordering** in `HeartbeatManager.register()` (`blockmanagement/HeartbeatManager.java:189‑196` → `addDatanode` :202‑207 → `Stats.add` :407‑422):

```java
void register(d):
  if (!d.isAlive) {
    addDatanode(d);            // stats.add(d): capacityUsedOther += d.getOtherUsed()  <-- reads STALE otherUsed
    d.updateHeartbeatState(EMPTY_ARRAY, ...);   // NOW zeroes d.otherUsed (line 194/436)
  }
```

`stats.add()` reads the node's fields *before* `updateHeartbeatState(EMPTY_ARRAY)` resets them.

### The exact failure path (branches taken)

Trace for the returning node, otherUsed = X:

1. **Node declared dead** → `DatanodeManager.removeDatanode()` (`DatanodeManager.java:543`):
   - `heartbeatManager.removeDatanode()` → `Stats.subtract()` (`HeartbeatManager.java:424‑439`) correctly removes X, capacity, dfsUsed, etc. Aggregate is now correct. `isAlive` set false (:213).
   - `blockManager.removeBlocksAssociatedTo()` (`DatanodeManager.java:546`) → `node.resetBlocks()` (`BlockManager.java:1124`). This zeroes capacity/dfsUsed/remaining/blockPoolUsed **but leaves `otherUsed = X`** on the descriptor.

2. **Node re-registers** → `registerDatanode`, `nodeS` found ("node restarted", `DatanodeManager.java:891`) → `heartbeatManager.register(nodeS)` (:934):
   - Branch `!d.isAlive` is **true** (set in step 1), so `addDatanode` runs.
   - `Stats.add()`: `capacityUsed += 0`, `capacityRemaining += 0`, `blockPoolUsed += 0` (all reset), **but `capacityUsedOther += node.getOtherUsed() = X`** (line 409). → the aggregate now carries a phantom X.
   - `updateHeartbeatState(EMPTY_ARRAY)` then sets `node.otherUsed = 0` (`DatanodeDescriptor.java:436`, empty-reports branch → `totalOtherUsed = 0`).

3. **Next heartbeat** → `HeartbeatManager.updateHeartbeat()` (:217‑225):
   - `stats.subtract(node)` subtracts `node.getOtherUsed() = 0` (field was zeroed in step 2) — so the phantom X is **never removed**.
   - `node.updateHeartbeat` sets the real current otherUsed; `stats.add(node)` adds it.

**Net:** `Stats.capacityUsedOther` = real value **+ X**, where X is the returning node's other-used space at the moment it died. `getOtherUsedSpace()` (`FSNamesystem.java:6866` → `getCapacityUsedOther`, `HeartbeatManager.java:143`) therefore reads ~1 node too high (~3 MB vs true ~2 MB).

Capacity, remaining, dfsUsed, blockPoolUsed do **not** leak precisely because `resetBlocks()` *does* zero them — so `addDatanode` adds 0 for them. Only `otherUsed`, the one field `resetBlocks()` forgets, survives as stale data and gets double-counted. No exception is thrown because this is pure arithmetic drift.

### The fix locus (not applied)
Adding `setOtherUsed(0)` to `resetBlocks()` (`DatanodeDescriptor.java:313`) would close the leak — making it symmetric with the other five fields so the register-time `Stats.add` contributes 0 for `otherUsed` as well.
