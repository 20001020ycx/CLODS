## Root cause

The cluster‑wide `otherUsedSpace` metric is tracked **incrementally** in `HeartbeatManager.Stats.capacityUsedOther`, kept in sync by `Stats.add()`/`Stats.subtract()`. The invariant those two methods rely on is: *whenever a live node's per‑field value changes, the change is bracketed by a `subtract(old)` … `add(new)` pair so the running total stays consistent with the node's current field.*

That invariant is broken **for `otherUsed` only**, because when a dead datanode's descriptor is scrubbed, every capacity field is zeroed **except** `otherUsed`.

### The defective line

`DatanodeDescriptor.resetBlocks()` — `/bug/source/.../blockmanagement/DatanodeDescriptor.java:313`

```java
public void resetBlocks() {
    setCapacity(0);        // 314
    setRemaining(0);       // 315
    setBlockPoolUsed(0);   // 316
    setDfsUsed(0);         // 317
    setXceiverCount(0);    // 318
    ...                    // <-- no setOtherUsed(0)  ← THE BUG
}
```

`capacity`, `remaining`, `blockPoolUsed`, `dfsUsed`, `xceiverCount` are reset; **`otherUsed` is left at its last stale value.** That single missing reset is the root cause.

## Exact failure path (branches that must be taken)

**1. Node declared dead** — `HeartbeatManager.heartbeatCheck()` finds it dead (`isDatanodeDead` true, line 296) → `dm.removeDeadDatanode(dead)` (line 332).
- `DatanodeManager.removeDeadDatanode:585` — branch `if (d != null && isDatanodeDead(d))` **true** → `removeDatanode(d)`.
- `DatanodeManager.removeDatanode:543`:
  - `heartbeatManager.removeDatanode(node)` → `Stats.subtract(node)` (HeartbeatManager:424‑426) with the node's **current** fields, correctly removing its `otherUsed = O` from `capacityUsedOther`. Cluster total is now correct.
  - `blockManager.removeBlocksAssociatedTo(node)` → **`node.resetBlocks()`** at `BlockManager.java:1124`. This zeroes `dfsUsed/capacity/remaining/blockPoolUsed` **but leaves `otherUsed = O` (stale)**.

Log evidence: `removeDeadDatanode: lost heartbeat from 127.0.0.1:44383` (symptom.log:4315) and `remove datanode 127.0.0.1:44383` (4461).

**2. Node re‑registers** — `DatanodeManager.registerDatanode`:
- `nodeS != null` (line 885) **true** and `nodeN == nodeS` (line 886) **true** → the *"node restarted."* branch (line 891; symptom.log:4468).
- Reaches `heartbeatManager.register(nodeS)` (line 934).
- `HeartbeatManager.register:190` — branch `if (!d.isAlive)` **true** →
  - `addDatanode(d)` → **`Stats.add(node)`** at HeartbeatManager:**409** `capacityUsedOther += node.getOtherUsed();`. Because `resetBlocks()` never cleared it, `getOtherUsed()` still returns the stale `O`, so `O` is folded back into the cluster total. (For dfsUsed/capacity/etc. `add` contributes `0`, since those *were* reset — which is why only the other‑used metric goes wrong.)
  - then `d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, …)` (line 194) → `setOtherUsed(0)` (DatanodeDescriptor:436, empty reports ⇒ `totalOtherUsed = 0`). This resets the **node field to 0 directly, not via a `Stats.subtract`**, so the stale `O` just added to `capacityUsedOther` is never taken back out.

Log evidence: `updateHeartbeatState … 0 to 0` + `pruneStorageMap … reports=0` (symptom.log:4471‑4474), i.e. the EMPTY_ARRAY registration heartbeat.

**3. First real heartbeat** — `HeartbeatManager.updateHeartbeat:221‑224`: `Stats.subtract(node)` removes `node.getOtherUsed() = 0`, then `node.updateHeartbeat` sets `otherUsed = O` again, then `Stats.add(node)` re‑adds `O`.

Net effect on `capacityUsedOther`: `(correct total after step 1) + O (step 2 addDatanode) − 0 + O (step 3) = correct + O`. The returning node's other‑used is counted **twice** → the metric is high by exactly one node's other‑used (~1 MB in the 2‑DN, ~2 MB‑true → ~3 MB‑reported case). `dfsUsed`, `capacity`, `remaining`, `blockPoolUsed` are unaffected because `resetBlocks()` zeroed them, so their `addDatanode` contribution at re‑registration was `0`.

## Where it surfaces
`FSNamesystem.getOtherUsedSpace()` (`FSNamesystem.java:6866`) returns `datanodeStatistics.getCapacityUsedOther()` → `Stats.capacityUsedOther` (`HeartbeatManager.java:143`), i.e. the now double‑counted running total. No exception is thrown and no per‑heartbeat operation can self‑correct it (later heartbeats do balanced `subtract/add`), so it stays permanently high — matching the symptom.

## Fix locus (not applied)
The asymmetry is entirely due to the omission at `DatanodeDescriptor.resetBlocks()` (lines 314‑317): it must also reset `otherUsed` (a `setOtherUsed(0)` alongside `setDfsUsed(0)`) so that, like every other capacity field, the stale other‑used cannot be re‑added by `Stats.add()` during `HeartbeatManager.register`/`addDatanode`.
