I have fully traced the failure path. Here is the root cause.

## Root cause

The cluster-wide "other-used" metric is **not recomputed** on demand — it is an incremental running total (`Stats.capacityUsedOther`) that every code path must keep in lock-step with each node's `otherUsed` field by symmetric `stats.add()` / `stats.subtract()` calls. The dead-node re-registration path violates that invariant, leaving a phantom copy of the node's other-used that the next heartbeat then counts a second time.

`FSNamesystem.getOtherUsedSpace()` (`FSNamesystem.java:6866-6867`) just returns `stats.capacityUsedOther` — it never sums live nodes, so any drift is permanent.

### The exact sequence (dn1 = the returning node, otherUsed = 5000)

**1. dn1 declared dead — correct.** `HeartbeatManager.removeDatanode` (`HeartbeatManager.java:209-215`): branch `if (node.isAlive)` is true → `stats.subtract(node)` reads `node.getOtherUsed()` **= 5000** (stats 10000 → 5000) and sets `isAlive = false`. Crucially, **the node's `otherUsed` field is only read, never cleared — it stays 5000.** (PROBE dead = 5000 ✓.)

**2. dn1 re-registers — the defect.** `DatanodeManager.registerDatanode` takes the "same datanode restarted" branch: `nodeS != null` (`:885`) and `nodeN == nodeS` (`:886`), reaching `heartbeatManager.register(nodeS)` at **`DatanodeManager.java:934`**.

`HeartbeatManager.register` (**`HeartbeatManager.java:189-196`**):
```java
if (!d.isAlive) {                 // line 190 — true, node was dead
  addDatanode(d);                 // line 191 → stats.add(d) uses STALE otherUsed=5000
  d.updateHeartbeatState(StorageReport.EMPTY_ARRAY, 0L, 0L, 0, 0, null); // line 194
}
```
- `addDatanode` → `stats.add(d)` (`:202-207`, add at `:409` `capacityUsedOther += node.getOtherUsed()`) adds the **stale 5000** → stats 5000 → 10000, `isAlive = true`.
- `d.updateHeartbeatState(EMPTY_ARRAY, …)` (`DatanodeDescriptor.java:363-436`): the report loop at `:416-428` never executes (empty array) so `totalOtherUsed = 0`, and `setOtherUsed(0)` at **`:436`** resets the node field to **0** — **without any matching `stats.subtract`.**

After step 2, the accounting is desynchronized: **stats attributes 5000 to dn1, but `dn1.otherUsed` now reads 0.** (Value happens to look right at 10000, but the invariant is broken.)

**3. First real heartbeat — double count surfaces.** `handleHeartbeat` (`DatanodeManager.java:1347`) → `HeartbeatManager.updateHeartbeat` (**`:217-225`**), which relies on stats currently holding exactly the node's field value:
```java
stats.subtract(node);            // line 221 — reads otherUsed = 0 → removes NOTHING (stats stays 10000)
node.updateHeartbeat(reports…);  //           → setOtherUsed(5000) from the storage report
stats.add(node);                 // line 224 — adds 5000 → stats 10000 → 15000
```
The `subtract` should have removed the 5000 that step 2 put in, but the field was zeroed to 0 in between, so it removes nothing; then `add` deposits a **second** 5000. Result: **15000** (PROBE rereg = 15000, ratio 1.5). No exception is thrown because nothing is invalid — the counter is simply wrong and stays wrong.

## The specific lines / branches that dictate the failure

1. **`HeartbeatManager.register`, `HeartbeatManager.java:190-194`** — inside the `if (!d.isAlive)` branch, it calls `addDatanode(d)` (→ `stats.add` at `:409` reading the **stale, never-cleared** `otherUsed`) and then immediately calls `d.updateHeartbeatState(EMPTY_ARRAY,…)` which zeroes the field **without a compensating `stats.subtract`**. This add-then-reset (as opposed to the subtract→update→add pattern used everywhere else) is the defect.
2. **`DatanodeDescriptor.updateHeartbeatState`, `:436` (`setOtherUsed(totalOtherUsed)` with `totalOtherUsed = 0` from the empty report loop at `:416-428`)** — clears the node's other-used out from under the incremental stats, breaking the "stats value == node field" invariant that `updateHeartbeat` depends on.
3. **`HeartbeatManager.updateHeartbeat`, `:221` and `:224`** — the `stats.subtract(node)` / `stats.add(node)` pair on the next heartbeat: `subtract` reads the zeroed field (removes 0) while `add` reads the freshly reported 5000, producing the net **+5000 double count**.
4. Reached via **`DatanodeManager.registerDatanode` restart branch, `:885` (`nodeS != null`) → `:886` (`nodeN == nodeS`) → `:934` (`heartbeatManager.register(nodeS)`)**, which is the path taken only for a previously-dead node that comes back with the same UUID.

The contrast that makes it a bug: `removeDatanode` (`:211`) and `updateHeartbeat` (`:221`/`:224`) keep stats and the node field consistent, but `register` (`:191` + `:194`) adds the stale value and then zeroes the field without a matching subtract — leaving stats holding a phantom copy of dn1's other-used that the first post-registration heartbeat counts again.
