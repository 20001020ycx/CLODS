## Root Cause

The NPE is a **missing null-check on a ZooKeeper znode that has already been deleted (or was never created)**. The state-transition path assumes the `/hbase/unassigned/<region>` znode always exists, but the ZK read path is explicitly documented to return `null` when the node is absent — and that `null` is fed straight into a deserializer that dereferences it.

## The failure path, line by line

**1. Log evidence.** In the exact same thread just before the NPE:

```
19:10:09,091 DEBUG ... zookeeper.ZKOps: regionserver:60020-...
   Could not read the contents of node /hbase/unassigned/1edc8893101fabdaabacd236d93e22ae
   since the node is absent (not necessarily an error)
19:10:09,097 ERROR ... executor.TaskHandler: Handler died on an unexpected error, task M_RS_BRINGUP_REGION
java.lang.NullPointerException
   at org.apache.hadoop.hbase.util.SerdeUtil.getWritable(SerdeUtil.java:75)
   ...
```

That "since the node is absent" message is emitted only from `ZKOps.getDataNoWatch` on the `NoNodeException` branch (source/java/org/apache/hadoop/hbase/zookeeper/ZKOps.java:589-592) — so the ZooKeeper read returned `null`.

**2. Caller does not handle the `null`.** In `RegionStateZK.transitionNode`:

```java
// RegionStateZK.java:670-673
byte [] existingBytes =
    ZKOps.getDataNoWatch(zkw, node, stat);        // returns null when znode is absent
RegionStateRecord existingData =
    RegionStateRecord.fromBytes(existingBytes);   // <-- no null check, called unconditionally
```

Note the javadoc at `RegionStateZK.java:632-635` promises "*If the node does not exist … the method returns -1*", but the code never implements that branch — it doesn't check `existingBytes == null` (nor `stat` untouched) before calling `fromBytes`. That is the primary bug.

**3. `fromBytes` passes the `null` byte[] on:**

```java
// RegionStateRecord.java:195-203
public static RegionStateRecord fromBytes(byte [] bytes) {
    try {
      RegionStateRecord data = new RegionStateRecord();
      SerdeUtil.getWritable(bytes, data);         // bytes == null → NPE inside
      return data;
    } ...
}
```

**4. The NPE site — `SerdeUtil.getWritable(byte[], Writable)`:**

```java
// SerdeUtil.java:73-76
public static Writable getWritable(final byte [] bytes, final Writable w)
throws IOException {
    return getWritable(bytes, 0, bytes.length, w);   // <-- line 75: bytes.length dereferences null
}
```

This is the two-arg overload. It dereferences `bytes.length` *before* delegating to the three-arg overload — even though the three-arg overload at `SerdeUtil.java:95-98` does have the guard:

```java
if (bytes == null || length <=0) {
    throw new IllegalArgumentException("Can't build a writable with empty bytes array");
}
```

The guard is unreachable when the caller uses the two-arg overload with `null`, because `bytes.length` throws NPE first.

## Which branches dictate the failure

The NPE-producing execution requires all of the following to be true on the region server thread `RS_REGION_BRINGUP-hbase-node-a,60021,1786971731434-0`:

1. `RegionBringupHandler.process` reaches `transitionZookeeperOfflineToOpening(encodedName)` (RegionBringupHandler.java:90), i.e.:
   - server not stopping (RegionBringupHandler.java:74),
   - region not already online (RegionBringupHandler.java:82 → `region == null`).
2. `RegionStateZK.transitionNode` reads the znode with `getDataNoWatch` (RegionStateZK.java:670-671).
3. Inside `ZKOps.getDataNoWatch`, `zk.getData(...)` takes the `KeeperException.NoNodeException` catch branch (ZKOps.java:589-592) and returns `null` — the `/hbase/unassigned/<encoded>` znode is missing at read time. In this cluster the master had already cleared/never-created that placement record for this bring-up (a race between master assignment/cleanup and the region server picking up `M_RS_BRINGUP_REGION`).
4. The caller *does not* branch on `existingBytes == null` (missing guard at RegionStateZK.java:672); it always calls `RegionStateRecord.fromBytes`.
5. `SerdeUtil.getWritable(byte[], Writable)` (the two-arg overload) is entered with `bytes == null` and evaluates `bytes.length` → `NullPointerException` at SerdeUtil.java:75.

## Fix location(s)

Any one of these fixes the crash; the semantically correct fix is (a):

- **(a) RegionStateZK.java:672** — honor the contract in the javadoc: if `existingBytes == null` (or `stat` shows the node absent), log the warning that "*the placement record does not exist*" and `return -1;` before calling `RegionStateRecord.fromBytes`. `transitionZookeeperOfflineToOpening` already treats `-1` as "someone stole the region" and returns cleanly (RegionBringupHandler.java:88-90, 303-308).
- **(b) SerdeUtil.java:73-76** — defensively null-check `bytes` in the two-arg overload so it throws `IllegalArgumentException` (matching the three-arg overload at line 95) instead of NPE. This turns the crash into the checked `IOException`/`IllegalArgumentException` path that `fromBytes` wraps in `RuntimeException` — still not friendly, so (a) is the real fix.

Summary: root cause is the missing "znode-absent" branch in `RegionStateZK.transitionNode` (RegionStateZK.java:670-673), triggered because the `/hbase/unassigned/<region>` znode had been deleted by the master before the region server's bring-up handler tried to read it; the crash surfaces at `SerdeUtil.java:75` where the two-arg `getWritable` dereferences `bytes.length` without first null-checking.
