## Root Cause

A missing null-check in `RegionStateZK.transitionNode` causes any ZooKeeper "node absent" reply on the OFFLINE→OPENING transition path to blow up the region-bringup handler with an NPE.

### The failure path in the log

For region `1edc8893101fabdaabacd236d93e22ae` (symptom.log:1083905–1083951):

1. **1083905** — RS begins `transitionNode` from `M_ZK_REGION_OFFLINE` → `RS_ZK_REGION_OPENING`.
2. **1083922** — ZK returns `replyHeader:: 926,1857,-101` on `/hbase/unassigned/1edc8893101fabdaabacd236d93e22ae` (`-101` = `NONODE`).
3. **1083930** — `ZKOps: Could not read the contents of node ... since the node is absent (not necessarily an error)` → `getDataNoWatch` returns `null`.
4. **1083939–1083951** — NPE inside `SerdeUtil.getWritable`, killing the `M_RS_BRINGUP_REGION` task.

The same pattern repeats hundreds of times, so every region assignment where the znode has been (or was never) created dies.

### Exact lines and branches

`RegionStateZK.transitionNode` (source/java/org/apache/hadoop/hbase/zookeeper/RegionStateZK.java:670–673):

```java
byte [] existingBytes =
  ZKOps.getDataNoWatch(zkw, node, stat);          // returns null when node absent (Code.NONODE)
RegionStateRecord existingData =
  RegionStateRecord.fromBytes(existingBytes);     // <-- null bytes handed straight in
```

There is no `if (existingBytes == null) return -1;` guard, even though this method's own Javadoc (lines 632–635) promises "If the node does not exist or the node is not in the expected state, the method returns -1." Compare with the sibling paths that DO handle it correctly: `deleteNode` at RegionStateZK.java:398–401 (`if(bytes == null) throw KeeperException.create(Code.NONODE);`), `getData` at 741–743, `getDataNoWatch` at 767–769, and `verifyRegionState` at 861 — all null-check before calling `fromBytes`.

`RegionStateRecord.fromBytes` (source/java/org/apache/hadoop/hbase/executor/RegionStateRecord.java:195–203) does no null-check either; it just forwards to:

`SerdeUtil.getWritable(byte[], Writable)` (source/java/org/apache/hadoop/hbase/util/SerdeUtil.java:73–76):

```java
public static Writable getWritable(final byte [] bytes, final Writable w)
throws IOException {
  return getWritable(bytes, 0, bytes.length, w);   // line 75: bytes.length NPEs when bytes==null
}
```

The 4-arg overload right below (lines 92–101) properly rejects null (`if (bytes == null || length <= 0) throw new IllegalArgumentException(...)`), but the 2-arg overload dereferences `bytes.length` *before* delegating — so a null argument becomes an NPE at line 75 instead of the intended `IllegalArgumentException`.

### Caller branch that triggers it

`RegionBringupHandler.process` (line 90) → `transitionZookeeperOfflineToOpening` (line 297) → `RegionStateZK.transitionNodeOpening(zkw, region, serverName)` (line 545) → overload at 549 → `transitionNode(..., beginState=M_ZK_REGION_OFFLINE, endState=RS_ZK_REGION_OPENING, expectedVersion=-1)` at line 552. Because `expectedVersion == -1`, the code never gets a chance to return early on a version-mismatch branch; it goes straight to the unguarded `fromBytes(existingBytes)` at line 673.

### Summary

Root cause: `RegionStateZK.transitionNode` does not honor its "node missing → return -1" contract. When the master hasn't (yet) created the OFFLINE znode — or it has been deleted — `ZKOps.getDataNoWatch` returns `null`, and that `null` is forwarded through `RegionStateRecord.fromBytes` into `SerdeUtil.getWritable(byte[], Writable)`, which reads `bytes.length` at SerdeUtil.java:75 and throws `NullPointerException`, aborting the bringup task. The fix is a null-guard on `existingBytes` in `transitionNode` (returning `-1`), and defensively adding the same null-check in `SerdeUtil.getWritable(byte[], Writable)` to convert this into the documented `IllegalArgumentException`.
