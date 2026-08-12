## Root cause

The inflation is caused by `HeartbeatManager.register()` (source/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java:189–196) adding **stale** per‑node counters into `Stats.capacityUsedOther` while the DatanodeDescriptor's `otherUsed` field is subsequently re‑zeroed without going through `stats.subtract` / `stats.add`. The result is a one‑time, orphaned `otherUsed` contribution that stays in the running total forever.

### The failure path, step by step (matches the log)

1. **DN 127.0.0.1:44383 is declared dead** — `HeartbeatManager.heartbeatCheck` (line 296 `if (dead == null && dm.isDatanodeDead(d))`) picks it up and calls `dm.removeDeadDatanode(dead)` (line 332). Log line 4315: `removeDeadDatanode: lost heartbeat from 127.0.0.1:44383`.

2. **removeDatanode** (DatanodeManager.java:543) runs:
   - `heartbeatManager.removeDatanode(nodeInfo)` → `HeartbeatManager.removeDatanode` (line 209) enters the `if (node.isAlive)` branch and calls `stats.subtract(node)` (line 211). That correctly removes the *current* `node.getOtherUsed()` (~1 MB for DN‑44383) from `stats.capacityUsedOther`, then sets `node.isAlive = false`.
   - `removeBlocksAssociatedTo(nodeInfo)` clears the blocks (log 4316‑4459), but **the DatanodeDescriptor is NOT wiped from `datanodeMap`/`host2DatanodeMap`, and its `capacity/dfsUsed/otherUsed` fields are NOT reset**. So the descriptor still carries its old `otherUsed` value (~1 MB).

3. **DN 44383 re‑registers** (log 4467) — `DatanodeManager.registerDatanode` (line 839). Because the descriptor was not wiped:
   - Line 871 `nodeS = getDatanode(uuid)` returns the old descriptor.
   - Line 872 `nodeN = host2DatanodeMap.getDatanodeByXferAddr(...)` returns the same descriptor, so `nodeN == nodeS` → the "node restarted" branch is taken (lines 885–907, "BLOCK* registerDatanode: node restarted." — log 4468).
   - Line 934 calls `heartbeatManager.register(nodeS)`.

4. **`HeartbeatManager.register(d)` — the buggy branch** (HeartbeatManager.java:189–196):
   ```java
   synchronized void register(final DatanodeDescriptor d) {
     if (!d.isAlive) {                // TRUE — set false in step 2
       addDatanode(d);                                          // <— (a)
       d.updateHeartbeatState(StorageReport.EMPTY_ARRAY,
                              0L, 0L, 0, 0, null);              // <— (b)
     }
   }
   ```
   - **(a) `addDatanode(d)` (line 202) calls `stats.add(d)` (line 204)** — and `Stats.add` at line 409 does
     ```java
     capacityUsedOther += node.getOtherUsed();
     ```
     using the **stale** ~1 MB value still sitting in the descriptor from before it was removed. `stats.capacityUsedOther` becomes ~2 MB again.
   - **(b) `d.updateHeartbeatState(EMPTY_ARRAY, …)`** in DatanodeDescriptor.java:363. The `for (StorageReport report : reports)` loop at line 416 does not execute (empty array), so `totalOtherUsed` stays 0 and line 436 `setOtherUsed(totalOtherUsed)` writes **0** into the descriptor. This never goes through `stats.subtract`, so the ~1 MB it just added stays in `stats.capacityUsedOther`. Log line 4471/4472/4473/4474 shows the same run of `updateHeartbeatState` — no storages reported → `pruneStorageMap` removes the last known storage.

5. **First real heartbeat after re‑register** (log 4476) — `HeartbeatManager.updateHeartbeat` (lines 217–225):
   ```java
   stats.subtract(node);            // node.getOtherUsed() is 0 → subtracts 0
   node.updateHeartbeat(reports,…); // otherUsed becomes ~1 MB again
   stats.add(node);                 // adds ~1 MB
   ```
   Net effect: `+1 MB` on top of the stale `+1 MB` from step 4a. `stats.capacityUsedOther` now = 1 MB (DN‑34275) + 1 MB (DN‑44383, added in 4a) + 1 MB (DN‑44383's real report added in step 5) ≈ **3 MB**, while the true value should be **2 MB**.

6. `FSNamesystem.getOtherUsedSpace()` (FSNamesystem.java:6866‑6868) returns `datanodeStatistics.getCapacityUsedOther()`, which is `stats.capacityUsedOther` (HeartbeatManager.java:143‑145) — hence the JMX/admin‑report value reads ~3 MB.

### The exact code responsible

`HeartbeatManager.register` at HeartbeatManager.java:189–196 does the two operations in the wrong order (or without wrapping them in a subtract/add pair):

- **HeartbeatManager.java:191 `addDatanode(d);`** — reads the stale `node.getOtherUsed()` via `Stats.add` at HeartbeatManager.java:409 (`capacityUsedOther += node.getOtherUsed();`).
- **HeartbeatManager.java:194 `d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, …);`** — through DatanodeDescriptor.java:427/436 zeroes the descriptor's `otherUsed` but never adjusts `stats`.

### Failing branch conditions summarised

- `DatanodeManager.isDatanodeDead(d)` true → `heartbeatCheck` invokes `removeDeadDatanode` (HeartbeatManager.java:296, 332 → DatanodeManager.java:585‑588).
- `removeDatanode` clears the node from `HeartbeatManager` and `NetworkTopology` but leaves `datanodeMap` / `host2DatanodeMap` and the descriptor's `otherUsed` field untouched.
- On re‑registration: `nodeS != null && nodeN == nodeS` at DatanodeManager.java:885/886 selects the "node restarted" path, which calls `heartbeatManager.register(nodeS)` at line 934.
- Inside `HeartbeatManager.register`, `!d.isAlive` at line 190 is true, so `addDatanode(d)` is executed **before** the descriptor is reset, leaking the old `otherUsed` into `stats.capacityUsedOther`.
- Every subsequent `updateHeartbeat` correctly subtracts/adds the delta, but never compensates for the leaked value — hence the persistent ~1 MB inflation.
