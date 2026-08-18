I have enough to diagnose. The picture is fully consistent between source and log.

## Root cause

The RegionServer's `RS_REGION_BRINGUP` handler is trying to move the `/hbase/unassigned/<encoded>` znode for a region from OFFLINE → OPENING, but that znode does not exist at the moment of the read. The read returns `null`, and a chain of missing null-checks turns "znode absent" (an expected, recoverable outcome — the caller of `transitionNode` is supposed to get `-1` back) into an unchecked `NullPointerException` that kills the executor task and aborts every region bring-up.

## The exact failure path (which branch each frame takes)

1. **`RegionBringupHandler.process` → `transitionZookeeperOfflineToOpening` (line 297)** calls `RegionStateZK.transitionNodeOpening(zkw, regionInfo, serverName)`. Straight-line, no branch.

2. **`RegionStateZK.transitionNodeOpening` (lines 542–553)** forwards to the private `transitionNode(zkw, region, serverName, EventType.M_ZK_REGION_OFFLINE, EventType.RS_ZK_REGION_OPENING, -1)`. Straight-line.

3. **`RegionStateZK.transitionNode` (lines 654–673)** reads the znode:
   ```java
   byte [] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);   // line 671
   RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);  // line 673
   ```
   There is **no null-check between these two lines**, even though the method's own javadoc (RegionStateZK.java:525) documents "Unassigned node for this region does not exist" as an expected failure that should return -1.

4. **`ZKOps.getDataNoWatch` (line 582)**: when the znode isn't there, ZooKeeper throws `KeeperException.NoNodeException`, which is caught at **line 589** and the method **returns `null`** (line 592). This is exactly the "not necessarily an error" branch and the log shows the same message being emitted for `/hbase/unassigned/<region>` many times (e.g. `logs/symptom.log:2910`, and around each `Handler died` occurrence). So `existingBytes == null` on the way into `fromBytes`.

5. **`RegionStateRecord.fromBytes` (lines 195–203)** does not check for null either — it constructs an empty record and calls
   ```java
   SerdeUtil.getWritable(bytes, data);   // line 198
   ```

6. **`SerdeUtil.getWritable(byte[], Writable)` (lines 73–76)** is where the NPE is actually thrown:
   ```java
   public static Writable getWritable(final byte [] bytes, final Writable w)
       throws IOException {
     return getWritable(bytes, 0, bytes.length, w);   // line 75  ← NPE
   }
   ```
   `bytes.length` is dereferenced **as part of computing the argument list**, before control ever reaches the 4-arg overload that would have detected the null:
   ```java
   if (bytes == null || length <= 0) {              // SerdeUtil.java:95-97
     throw new IllegalArgumentException(...);
   }
   ```
   Because the null-check lives in the callee but the null-dereference happens in the caller's argument evaluation, `bytes == null` skips the guarded branch entirely and hits an unguarded field access → `NullPointerException` at `SerdeUtil.java:75`. That matches the stack top exactly.

## Which branches must be true for the failure to occur

- In `ZKOps.getDataNoWatch`, the `catch (KeeperException.NoNodeException e)` branch (ZKOps.java:589) is taken, so **`existingBytes == null`**. (`stat` is also never populated.)
- In `RegionStateZK.transitionNode`, the **absent** null-check between lines 671 and 673 lets the null flow into `RegionStateRecord.fromBytes`.
- In `RegionStateRecord.fromBytes` (line 198), no null-check either, so the null flows into `SerdeUtil.getWritable`.
- In `SerdeUtil.getWritable(byte[], Writable)` (line 75), `bytes.length` is evaluated on a null reference → NPE. The seemingly-defensive null check at lines 95–97 in the 4-arg overload is dead code on this path — it can never be reached from the 2-arg overload because the 2-arg overload dereferences `bytes` before delegating.

## Underlying trigger

The `/hbase/unassigned/<encoded-region>` znode is missing when the region server begins its OFFLINE→OPENING transition. The log shows this znode-absent condition (e.g. line 2910: "Could not read the contents of node `/hbase/unassigned/70236052` because node does not exist (not an error)"), and each region bring-up on `hbase-node-a` fails immediately afterwards with the same NPE stack (lines 1083939, 1084002, 1084081, 1084144, 1084207, 1084287, 1084350, …). Because the handler dies on every attempt and returns no version, every region bring-up on that server keeps failing.

## Fix locations (in order of severity)

- **`SerdeUtil.java:73-76`** — the 2-arg `getWritable` must guard against `bytes == null` before dereferencing `bytes.length` (either check first, or delegate via `bytes == null ? 0 : bytes.length`). This is the direct cause of the NPE.
- **`RegionStateZK.java:671-673`** — `transitionNode` must handle `existingBytes == null` (znode absent) as the documented "Unassigned node for this region does not exist" case and return `-1` with a warning, rather than blindly deserializing.
- **`RegionStateRecord.java:195-203`** — `fromBytes(null)` should return null (or the caller should never call it with null); either would have contained the failure.
