## Root cause

The cluster‑wide `capacityUsedOther` (exposed as `getOtherUsedSpace`) double‑counts a re‑registering DataNode because, on re‑registration, `HeartbeatManager.register()` **adds the node's stale `otherUsed` into the aggregate before that field is reset to 0**, and no matching subtract ever removes it. The next real heartbeat then adds the node's true `otherUsed` a second time.

The log confirms the arithmetic exactly: `10000` (both live) → `5000` (dn1 dead, correctly subtracted) → **`15000`** (dn1 re‑registered → `+10000` for one node = counted twice).

### The failure path, line by line

**1. Death — subtract happens correctly (so the imbalance is entirely on the add side)**

`heartbeatCheck` → `DatanodeManager.removeDeadDatanode` (`DatanodeManager.java:585` branch `d != null && isDatanodeDead(d)`) → private `removeDatanode` (`DatanodeManager.java:543`) → `HeartbeatManager.removeDatanode`:

```
HeartbeatManager.java:210   if (node.isAlive) {          // TRUE
HeartbeatManager.java:211     stats.subtract(node);      // capacityUsedOther -= 5000  → 5000
HeartbeatManager.java:213     node.isAlive = false;
```

`Stats.subtract` line `426` (`capacityUsedOther -= node.getOtherUsed()`) removes the correct 5000. **Crucially, nothing resets the descriptor's `otherUsed` field** — it stays `5000`, and the descriptor is *not* wiped from `datanodeMap` (private `removeDatanode` never calls `wipeDatanode`).

**2. Re‑registration — the "same node restarted" branch**

`DatanodeManager.registerDatanode`:
```
DatanodeManager.java:885   if (nodeS != null) {          // TRUE  (descriptor still in datanodeMap)
DatanodeManager.java:886     if (nodeN == nodeS) {       // TRUE  ("node restarted")
DatanodeManager.java:934   heartbeatManager.register(nodeS);
```

**3. The defect — `register()` adds stale stats, then zeroes the field**

```
HeartbeatManager.java:190   if (!d.isAlive) {                                   // TRUE (declared dead)
HeartbeatManager.java:191     addDatanode(d);                                   // → stats.add(d)
HeartbeatManager.java:194     d.updateHeartbeatState(EMPTY_ARRAY, 0L, ...);     // resets fields to 0
```

- `addDatanode` → `stats.add(d)` (`HeartbeatManager.java:204`), and `Stats.add` line `409`:
  `capacityUsedOther += node.getOtherUsed()` reads the **stale 5000** → aggregate `5000 → 10000`.
- Only *after* that (`HeartbeatManager.java:194`) does `updateHeartbeatState(EMPTY_ARRAY,…)` run. With empty reports, `DatanodeDescriptor.updateHeartbeatState` leaves `totalOtherUsed = 0` (loop at `416‑428` never executes) and calls `setOtherUsed(0)` at `DatanodeDescriptor.java:436`. This zeroes the descriptor field **but performs no `stats.subtract`** — so the phantom 5000 is now permanently stuck in the aggregate.

**4. First real heartbeat — adds the true value on top**

`DatanodeManager.handleHeartbeat` → `HeartbeatManager.updateHeartbeat` (`217‑225`):
```
HeartbeatManager.java:221   stats.subtract(node);   // subtracts otherUsed = 0  (field was just reset!) → still 10000
HeartbeatManager.java:222   node.updateHeartbeat(...); // setOtherUsed(5000)
HeartbeatManager.java:224   stats.add(node);        // capacityUsedOther += 5000 → 15000
```

The subtract at line `221` removes **0** instead of the value that was actually injected at register time, and the add at line `224` puts in a fresh 5000.

### Net effect

For the returning node, `capacityUsedOther` receives **two adds of 5000** (register `addDatanode`, then the first heartbeat `updateHeartbeat`) but only the death subtract (5000) and a useless subtract of 0. Result: one extra 5000 → `15000` instead of `10000`, and it stays wrong.

### The controlling conditions (branches that must all hold)

- `HeartbeatManager.java:190` `if (!d.isAlive)` — true only because the node was previously declared dead (a live re‑register would skip the erroneous `addDatanode`, which is why the bug is specific to the dead→re‑register cycle).
- `DatanodeManager.java:885/886` `nodeS != null && nodeN == nodeS` — the "same storage restarted" path, which reuses the old descriptor still carrying `otherUsed = 5000`.
- Ordering at `HeartbeatManager.java:191` then `:194` — `stats.add` (reading the stale field via `Stats.add:409`) executes **before** `updateHeartbeatState` resets that field, and the reset is not paired with a `stats.subtract`.
- The death path (`HeartbeatManager.java:211` `stats.subtract`) never resets `DatanodeDescriptor.otherUsed`, so the value survives to be re‑added.

The fresh‑node path (`DatanodeManager.java:948‑970`) does **not** trigger this, because it builds a brand‑new `DatanodeDescriptor` whose `otherUsed` is 0, so `addDatanode`'s `stats.add` injects nothing.
