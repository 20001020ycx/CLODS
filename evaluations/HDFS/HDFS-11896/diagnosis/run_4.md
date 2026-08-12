## Root cause

The inflated `getOtherUsedSpace` is caused by a stale-value accumulation in `HeartbeatManager.register()` when a previously-dead DataNode re-registers with the NameNode.

### The failure path in the log

The log records the exact scenario:

- `logs/symptom.log:4315` — the DataNode at `127.0.0.1:44383` is declared dead:
  `BLOCK* removeDeadDatanode: lost heartbeat from 127.0.0.1:44383`.
- `logs/symptom.log:4461` — `DatanodeManager.removeDatanode(551)` runs, which calls `HeartbeatManager.removeDatanode`.
- `logs/symptom.log:4462-4470` — the same DN restarts and re-registers (`registerDatanode: … storage 96d10ee7…`, `node restarted.`).
- `logs/symptom.log:4471-4474` — the re-registration is treated as a heartbeat with an **empty** `StorageReport[]` (`Number of storages reported in heartbeat=0`).

### The buggy code path

1. `DatanodeManager.registerDatanode` (…/DatanodeManager.java:934) invokes `heartbeatManager.register(nodeS)` for the restarted DN.
2. `HeartbeatManager.register` (…/HeartbeatManager.java:189-196):

   ```java
   synchronized void register(final DatanodeDescriptor d) {
     if (!d.isAlive) {                                             // TRUE — it was declared dead
       addDatanode(d);                                             // (A) adds STALE d.getOtherUsed()
       d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, ...);     // (B) zeroes d, aggregate untouched
     }
   }
   ```

   - Branch (`!d.isAlive`) is taken because `HeartbeatManager.removeDatanode` (line 209-215) only set `node.isAlive = false`; it did **not** clear the per-DN fields `capacity/dfsUsed/otherUsed/…` on the `DatanodeDescriptor`.
   - `addDatanode(d)` (line 202-207) calls `stats.add(d)`, which at line 409 does `capacityUsedOther += node.getOtherUsed();` — but `node.getOtherUsed()` still returns the DN's **last-heartbeated** `otherUsed` from before it died (~1 MB).
   - Immediately after, `d.updateHeartbeatState(EMPTY_ARRAY, …)` runs `DatanodeDescriptor.updateHeartbeatState` (…/DatanodeDescriptor.java:363-436): the loop at line 416-428 does not execute because `reports.length == 0`, so `totalOtherUsed` stays 0 and `setOtherUsed(0)` (line 436) resets the descriptor. The aggregate `stats.capacityUsedOther` is **not** decremented.

   Net effect after `register`: `stats.capacityUsedOther` has been incremented by the DN's old value, but the DN's own `otherUsed` is now 0 — a phantom contribution is orphaned in the aggregate.

3. The DN's next real heartbeat goes through `HeartbeatManager.updateHeartbeat` (line 217-225):

   ```java
   stats.subtract(node);                          // subtracts 0 (descriptor was reset in step 2B)
   node.updateHeartbeat(reports, ...);            // sets descriptor.otherUsed = 1 MB (real value)
   stats.add(node);                               // adds 1 MB
   ```

   The `subtract` at line 426 removes 0 because the descriptor was zeroed in step 2B, but `add` at line 409 re-adds the real ~1 MB. So the aggregate still carries the phantom ~1 MB from step 2A **on top of** the truly-live datanodes' contributions.

### Why the number is 3 MB instead of 2 MB

Two live DNs each report ~1 MB of `otherUsed` → the correct aggregate is 2 MB. The DN that died and re-registered leaves behind a ~1 MB phantom contribution added inside `register`, so `stats.capacityUsedOther` becomes 3 MB. That is exactly what `FSNamesystem.getOtherUsedSpace()` (…/FSNamesystem.java:6866-6867) returns via `datanodeStatistics.getCapacityUsedOther()` (implemented at HeartbeatManager.java:143-145 as `return stats.capacityUsedOther;`).

### The specific fault

`HeartbeatManager.register` at **HeartbeatManager.java:189-196** — the sequence `addDatanode(d); d.updateHeartbeatState(EMPTY_ARRAY, …);` reads `d.getOtherUsed()` (via `Stats.add`, HeartbeatManager.java:409) **before** the descriptor's stale per-DN counters have been cleared. The branch condition `if (!d.isAlive)` (i.e. re-registering a previously-declared-dead DataNode whose `DatanodeDescriptor` was left with non-zero `otherUsed/dfsUsed/capacity/remaining/blockPoolUsed` by `removeDatanode`) is what turns this ordering into a leak into `stats.capacityUsedOther`.
