## Root cause

The extra ~1 MB comes from a stale `otherUsed` value being **added twice** to the cluster-wide `capacityUsedOther` when a datanode is removed as dead and then re-registers with the same UUID (the "node restarted" path visible at log line 4468: `BLOCK* registerDatanode: node restarted.`).

### The failure path

1. **Datanode dies** — `HeartbeatManager.heartbeatCheck` at `HeartbeatManager.java:296-332` detects the expired heartbeat (log line 4315, `removeDeadDatanode: lost heartbeat from 127.0.0.1:44383`). It calls `DatanodeManager.removeDeadDatanode` → `removeDatanode` (`DatanodeManager.java:543-554`), which calls `heartbeatManager.removeDatanode(nodeInfo)`.

2. **`HeartbeatManager.removeDatanode`** (`HeartbeatManager.java:209-215`) executes the branch `if (node.isAlive)` → `stats.subtract(node)` and sets `node.isAlive = false`. Crucially, **it never resets `node.otherUsed`**; the `DatanodeDescriptor` object is retained in `datanodeMap` with its *stale* per-node fields (`dfsUsed`, `otherUsed`, `blockPoolUsed`) still holding the pre-death values.

3. **Datanode re-registers** with the same UUID (log line 4467). `DatanodeManager.registerDatanode` at `DatanodeManager.java:871` calls `getDatanode(nodeReg.getDatanodeUuid())` and reuses the *same* stale descriptor `nodeS`. Since `nodeN == nodeS`, control takes the "node restarted" branch (`DatanodeManager.java:886-893`) and then reaches `heartbeatManager.register(nodeS)` at `DatanodeManager.java:934`.

4. **The bug is in `HeartbeatManager.register`** at `HeartbeatManager.java:189-196`:

   ```java
   synchronized void register(final DatanodeDescriptor d) {
     if (!d.isAlive) {                                      // line 190 – true, because removeDatanode set it false
       addDatanode(d);                                      // line 191 – calls stats.add(d) using STALE fields
       d.updateHeartbeatState(StorageReport.EMPTY_ARRAY,    // line 194 – only NOW zeroes d.otherUsed
                              0L, 0L, 0, 0, null);
     }
   }
   ```

   `addDatanode(d)` (`HeartbeatManager.java:202-207`) calls `stats.add(d)`, and inside `Stats.add` at `HeartbeatManager.java:407-409`:

   ```java
   capacityUsed        += node.getDfsUsed();
   capacityUsedOther   += node.getOtherUsed();   // line 409 – reads the STALE ~1 MB
   blockPoolUsed       += node.getBlockPoolUsed();
   ```

   Because line 191 runs **before** line 194, `stats.add` reads the pre-death `otherUsed` (~1 MB) from the descriptor and adds it to `capacityUsedOther`. Only afterward does line 194 call `d.updateHeartbeatState(EMPTY_ARRAY, …)`, which walks a zero-length `reports[]` (loop at `DatanodeDescriptor.java:416-428`), leaves `totalOtherUsed = 0`, and does `setOtherUsed(0)` at `DatanodeDescriptor.java:436` — resetting the field on the descriptor **but not undoing the stale contribution already made to `stats.capacityUsedOther`**.

5. **First real heartbeat afterward** goes through `HeartbeatManager.updateHeartbeat` (`HeartbeatManager.java:217-225`):

   ```java
   stats.subtract(node);                    // subtracts 0 (d.otherUsed was just zeroed)
   node.updateHeartbeat(reports, …);        // sets d.otherUsed = ~1 MB (real value)
   stats.add(node);                         // adds ~1 MB back
   ```

   So the stale ~1 MB injected at step 4 is never removed.

### Arithmetic matching the symptom

With two datanodes each reporting `otherUsed ≈ 1 MB`:

| Event | `stats.capacityUsedOther` |
|---|---|
| Initial `add` for both DNs | 2 MB |
| Dead DN removed → `stats.subtract` (real 1 MB) | 1 MB |
| Re-register → `addDatanode` → `stats.add` (STALE 1 MB, line 409) | **2 MB** |
| `updateHeartbeatState(EMPTY_ARRAY,…)` zeroes only `d.otherUsed` | 2 MB |
| Real HB: `stats.subtract` (0) + `stats.add` (real 1 MB) | **3 MB** ← reported |

Expected: 2 MB. Reported: ~3 MB. Matches the symptom.

### The exact fault
- **File / lines:** `org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java:189-196` (`register`), whose `addDatanode(d)` call at line 191 feeds `Stats.add` at line 409 (`capacityUsedOther += node.getOtherUsed();`) with a stale `DatanodeDescriptor.otherUsed`.
- **Branch conditions on the failure path:**
  - `HeartbeatManager.register` line 190: `if (!d.isAlive)` — true because the descriptor was marked dead by `removeDatanode` at line 213 without clearing its `otherUsed` field.
  - `DatanodeManager.registerDatanode` line 885/886: `if (nodeS != null)` and `if (nodeN == nodeS)` — the "node restarted" branch, which reuses the stale descriptor and calls `heartbeatManager.register(nodeS)` at line 934.
  - `HeartbeatManager.heartbeatCheck` line 324: `if (dead != null)` invoking `dm.removeDeadDatanode(dead)` (log line 4315) — the trigger that leaves the stale descriptor behind in the first place.

Fix would be to zero the descriptor's per-node counters *before* calling `stats.add` (e.g. reverse the order in `register`: call `d.updateHeartbeatState(EMPTY_ARRAY,…)` first, then `addDatanode(d)`), or have `removeDatanode` reset those fields when marking the descriptor dead.
