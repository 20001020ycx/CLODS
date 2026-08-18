Confirmed. Here is the diagnosis.

## Root cause

The region‑server bring‑up path tries to flip the region's ZooKeeper *unassigned* znode from `M_ZK_REGION_OFFLINE` to `RS_ZK_REGION_OPENING`, but that znode does **not exist** in ZooKeeper. The code never checks for that case, so it hands `null` bytes to a deserializer that immediately dereferences them.

## The failure path, step by step

1. `RegionBringupHandler.process` → `transitionZookeeperOfflineToOpening` (RegionBringupHandler.java:90 → :297) calls:
   ```
   RegionStateZK.transitionNodeOpening(...)         // :545
     → transitionNodeOpening(..., M_ZK_REGION_OFFLINE) // :552
       → transitionNode(...)                        // :654
   ```

2. Inside `transitionNode` (RegionStateZK.java:654) the critical lines are:

   ```
   670  byte [] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);
   672  RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);
   ```

   `ZKOps.getDataNoWatch` (ZKOps.java:582‑599) catches `KeeperException.NoNodeException` and **returns `null`** after logging  
   `"Could not read the contents of node ... since the node is absent (not necessarily an error)"`.  
   The very same "node does not exist" DEBUG line is all over `symptom.log` for `/hbase/unassigned/...` and `/hbase/meta-region-server` — confirming the znode really is missing when the handler runs.

3. `existingBytes == null` is **never checked**. Control drops straight into `RegionStateRecord.fromBytes(null)` (RegionStateRecord.java:195):

   ```
   197  RegionStateRecord data = new RegionStateRecord();
   198  SerdeUtil.getWritable(bytes, data);   // bytes == null
   ```

4. `SerdeUtil.getWritable(byte[], Writable)` at SerdeUtil.java:73‑76 is the single‑arg overload; **before** any of its guard checks, its only line is:

   ```
   75  return getWritable(bytes, 0, bytes.length, w);
   ```

   Evaluating `bytes.length` on a `null` reference throws `NullPointerException` — exactly the frame at the top of the stack. Note that the three‑arg overload (lines 92‑101) *does* have a `bytes == null` guard that would throw `IllegalArgumentException` instead, but that guard is never reached because the NPE happens while computing the argument to the call.

5. The NPE propagates back up through `fromBytes` (which only catches `IOException`, not `RuntimeException`) → `transitionNode` (also only declares `KeeperException`) → `transitionZookeeperOfflineToOpening` → `RegionBringupHandler.process` → `TaskHandler.run` (TaskHandler.java:151). `TaskHandler.run` logs `"Handler died on an unexpected error, task M_RS_BRINGUP_REGION"` and the region bring‑up is aborted, so the region never comes online. Because the master keeps re‑assigning, the same NPE repeats for every region and every bring‑up thread — which is exactly what the log shows (`RS_REGION_BRINGUP-hbase-node-a,60020,...` firing at 19:10:09.097, .133, .148, .154, .169, .185, .563, .578, …).

## Exact branches that dictate the failure

- **RegionStateZK.transitionNode**, line 670–673: the code takes the branch where `existingBytes` returned by `ZKOps.getDataNoWatch` is `null` (znode absent), but has no `if (existingBytes == null) return -1;` guard before invoking `RegionStateRecord.fromBytes`. Per its own Javadoc ("Unassigned node for this region does not exist" is a documented `-1` case) this branch was supposed to log a warn and return `-1`; instead it falls through.
- **ZKOps.getDataNoWatch**, line 589–592: the `NoNodeException` catch returns `null` rather than propagating, so callers must handle `null` — and this one doesn't.
- **SerdeUtil.getWritable(byte[], Writable)**, line 75: the one‑liner dereferences `bytes.length` *before* delegating to the guarded three‑arg overload, so a `null` array becomes an NPE instead of the `IllegalArgumentException` the guards were designed to raise.
- **RegionStateRecord.fromBytes**, line 198: only `IOException` is caught; a `RuntimeException` such as NPE escapes to `TaskHandler.run`, killing the handler.

## Fix

The minimal, correct fix is in `RegionStateZK.transitionNode` — treat a missing znode as the documented "node does not exist" failure:

```java
byte[] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);
if (existingBytes == null) {
  LOG.warn(zkw.prefix("Attempt to transition the placement record of " + encoded +
      " from " + beginState + " to " + endState +
      " failed, the node does not exist"));
  return -1;
}
RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);
```

Optionally harden `SerdeUtil.getWritable(byte[], Writable)` (SerdeUtil.java:73) to check `bytes == null` before touching `bytes.length`, so future callers get an `IllegalArgumentException` rather than an NPE — but the root cause is the missing null check in `transitionNode`.
