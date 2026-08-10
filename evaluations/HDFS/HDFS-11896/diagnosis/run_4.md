## Root Cause

The double-count is produced by an **ordering inconsistency in `HeartbeatManager.register()`**: it adds the returning node's *stale* `otherUsed` value into the running `Stats.capacityUsedOther` accumulator, then immediately resets the node's own `otherUsed` field to 0 **without** adjusting the accumulator. The next real heartbeat then re-adds the true value on top, leaving the stale contribution permanently stranded in the total.

The log confirms the trajectory exactly:
- `PROBE alive: cluster_otherUsed=10000` (correct)
- `PROBE dead: cluster_otherUsed=5000` (correct — the death subtraction works)
- `PROBE rereg: cluster_otherUsed=15000` (wrong — should be 10000)

### The exact code path

**1. Death (works correctly).** `HeartbeatManager.removeDatanode` — `/bug/source/.../blockmanagement/HeartbeatManager.java:209`

```java
synchronized void removeDatanode(DatanodeDescriptor node) {
  if (node.isAlive) {                 // line 210 — TRUE, node is live
    stats.subtract(node);             // line 211 — capacityUsedOther -= 5000  → 10000→5000
    datanodes.remove(node);           // line 212 — leaves live set
    node.isAlive = false;             // line 213
  }
}
```

Crucially, this **does not reset the descriptor's `otherUsed` field** — `node.getOtherUsed()` still returns the pre-death **5000**. The reused `DatanodeDescriptor` (kept in `datanodeMap`) carries this stale value.

**2. Re-registration (introduces the leak).** During `DatanodeManager.registerDatanode`, because the same UUID/address is found, the `nodeN == nodeS` "node restarted" branch is taken (`DatanodeManager.java:886`), and the existing descriptor is passed to `heartbeatManager.register(nodeS)` (`DatanodeManager.java:934`).

`HeartbeatManager.register` — `HeartbeatManager.java:189`

```java
synchronized void register(final DatanodeDescriptor d) {
  if (!d.isAlive) {                                            // line 190 — TRUE (isAlive was set false on death)
    addDatanode(d);                                            // line 191 → stats.add(d)
    d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, 0L, 0L, 0, 0, null); // line 194
  }
}
```

- **Line 191 → `addDatanode` (line 202) → `stats.add(d)` (line 204).** `Stats.add` at **line 409** executes `capacityUsedOther += node.getOtherUsed();` using the **stale 5000** → accumulator goes `5000 → 10000`.
- **Line 194 `updateHeartbeatState(EMPTY_ARRAY,...)`** runs `DatanodeDescriptor.updateHeartbeatState` (line 363). With an empty report array the loop at line 416 never executes, so `totalOtherUsed` stays 0 and **line 436 `setOtherUsed(totalOtherUsed)` sets the field to 0** — but this call does **not** touch `Stats.capacityUsedOther`.

After `register()`: the accumulator holds 5000 for this node, but the descriptor's `otherUsed` field says **0**. The invariant "the accumulator equals the sum of each live node's current field" is now broken.

**3. Next heartbeat (materializes the double count).** `HeartbeatManager.updateHeartbeat` — `HeartbeatManager.java:217`

```java
stats.subtract(node);            // line 221 — capacityUsedOther -= node.getOtherUsed() == 0  → stays 10000
node.updateHeartbeat(reports...);// line 222 — sets otherUsed back to 5000
stats.add(node);                 // line 224 — capacityUsedOther += 5000  → 15000
```

The subtract at line 221 removes only the **current field value (0)**, not the 5000 that `register()` actually injected. The add at line 224 then puts the real 5000 back on top → **15000**.

`getOtherUsedSpace()` (`FSNamesystem.java:6866`) returns this via `getCapacityUsedOther()` (`HeartbeatManager.java:143`) → `stats.capacityUsedOther`, so the metric reads 15000 and stays wrong.

### The decisive branches

1. `HeartbeatManager.removeDatanode:210` (`node.isAlive` TRUE) — subtracts on death but **leaves `otherUsed` field stale at 5000**.
2. `HeartbeatManager.register:190` (`!d.isAlive` TRUE) — enters the re-add path with a reused, stale descriptor.
3. `Stats.add:409` — adds the **stale** `getOtherUsed()` (5000) into the accumulator.
4. `DatanodeDescriptor.updateHeartbeatState:416/436` (empty reports → `setOtherUsed(0)`) — resets the field to 0 **without** a matching `stats.subtract`, so `register()`'s add is never balanced.
5. `HeartbeatManager.updateHeartbeat:221/224` — subtract uses the now-0 field, add re-inserts 5000, stranding the earlier 5000.

### Why fresh registrations don't hit it
A brand-new node takes `DatanodeManager.java:948-970`: a freshly constructed `DatanodeDescriptor` whose constructor already set `otherUsed=0` (line 240/251), so `heartbeatManager.addDatanode` adds 0 — consistent with the field. Only the **restart/re-registration of a previously-dead descriptor** carries a stale non-zero `otherUsed` at the moment `Stats.add` reads it, which is what makes the returning node's other-used space counted twice.
