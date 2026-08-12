## Root cause

The bug is in `HeartbeatManager.register()` when a previously-dead DataNode re-registers. The aggregate `stats.capacityUsedOther` gets a stale contribution added into it, so the JMX `CapacityUsedOther` / `getOtherUsedSpace()` value stays permanently inflated by whatever the dead node's `otherUsed` was at the moment it died (~1 MB here — giving 2 MB legitimate + 1 MB leaked ≈ 3 MB).

### The failure path

1. **Dead-node detection** — `DatanodeManager.removeDeadDatanode()` (source/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeManager.java:577‑591) sees the expired heartbeat from `127.0.0.1:44383` (log line 4315) and calls `removeDatanode(d)` → `heartbeatManager.removeDatanode(nodeInfo)` (line 545). That method (`HeartbeatManager.java:209‑215`) does
   ```java
   if (node.isAlive) {
     stats.subtract(node);
     datanodes.remove(node);
     node.isAlive = false;
   }
   ```
   Important: it only decrements `stats` and flips `isAlive`. It does **not** clear the descriptor's own `dfsUsed / otherUsed / capacity / remaining` fields, and it does **not** call `wipeDatanode`, so the `DatanodeDescriptor` object remains in `datanodeMap` with its pre-death numeric fields intact (in particular `otherUsed = X ≈ 1 MB`).

2. **Re-registration** — 973 ms later (log line 4467) the same DN registers again. In `DatanodeManager.registerDatanode()` (DatanodeManager.java:871‑946), `nodeS = getDatanode(uuid)` returns the retained descriptor, `nodeN == nodeS`, so the "node restarted." branch (line 891) is taken and control reaches `heartbeatManager.register(nodeS)` at line 934. This is confirmed by log line 4468 (`registerDatanode: node restarted.`).

3. **The buggy branch** — `HeartbeatManager.register()` at lines 189‑196:
   ```java
   synchronized void register(final DatanodeDescriptor d) {
     if (!d.isAlive) {          // TRUE — removeDatanode set it false in step 1
       addDatanode(d);          // <-- BUG: runs BEFORE the reset below
       d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, 0L, 0L, 0, 0, null);
     }
   }
   ```
   `addDatanode(d)` (line 202‑207) calls `stats.add(d)`, and `Stats.add` (line 407‑422) reads the descriptor's *current* fields:
   ```java
   capacityUsedOther += node.getOtherUsed();   // line 409  -> adds stale X back in
   ```
   So the ~1 MB that had just been subtracted in step 1 is re-added to the aggregate.

4. **The reset happens too late** — `d.updateHeartbeatState(EMPTY_ARRAY, …)` (HeartbeatManager.java:194) enters `DatanodeDescriptor.updateHeartbeatState` (DatanodeDescriptor.java:363‑444). With an empty reports array, the `for (StorageReport report : reports)` loop (line 416‑428) never executes, so `totalOtherUsed` stays 0 and line 436
   ```java
   setOtherUsed(totalOtherUsed);   // 0
   ```
   zeroes out the descriptor's `otherUsed`. Crucially this reset only touches the descriptor — it does **not** decrement the aggregate `stats.capacityUsedOther` that `addDatanode` just inflated.

5. **Subsequent heartbeats can't cure it** — the very next real heartbeat runs `HeartbeatManager.updateHeartbeat()` at lines 217‑225:
   ```java
   stats.subtract(node);                  // subtracts 0 (node.otherUsed was reset to 0)
   node.updateHeartbeat(reports, …);      // sets node.otherUsed = Y (fresh value)
   stats.add(node);                       // adds Y
   ```
   Net change from this cycle is `+Y`, which is correct in isolation — but the stale `X` added in step 3 was never removed, so from now on `stats.capacityUsedOther = X + Y ≈ 1 MB + 2 MB = 3 MB`. Every future `getOtherUsedSpace()` read (FSNamesystem.java:6866‑6868 → HeartbeatManager.java:143‑145) returns this inflated value.

### The exact logical conditions

- `HeartbeatManager.removeDatanode` at lines 209‑215 subtracts stats and sets `node.isAlive = false` but leaves the descriptor's fields populated (and the descriptor kept in `datanodeMap` because `removeDatanode(DatanodeDescriptor)` in DatanodeManager.java:543‑554 never calls `wipeDatanode`).
- `HeartbeatManager.register` at lines 189‑196 takes the `!d.isAlive == true` branch and orders the two calls wrong: `addDatanode(d)` (line 191) runs **before** `d.updateHeartbeatState(EMPTY_ARRAY, …)` (line 194).
- `Stats.add` at line 409 (`capacityUsedOther += node.getOtherUsed();`) therefore picks up the stale pre-death value.
- `DatanodeDescriptor.updateHeartbeatState` at lines 416‑428 + line 436 (`setOtherUsed(totalOtherUsed)`) then zeros the descriptor field with an empty-reports loop, but never adjusts `stats`, permanently leaking the difference.

The correct ordering would be to zero the descriptor first, e.g. call `d.updateHeartbeatState(EMPTY_ARRAY, …)` before `addDatanode(d)` (or reset the descriptor's stat fields inside `removeDatanode`), so `stats.add` sees a clean slate.
