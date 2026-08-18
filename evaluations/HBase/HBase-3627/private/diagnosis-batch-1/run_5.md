## Root cause

An NPE at `SerdeUtil.getWritable` because `ZKOps.getDataNoWatch` returned `null` (the ZK unassigned znode did not exist / could not be read), and the code path from the region server bring-up handler through `RegionStateZK.transitionNode` does not null-check the bytes before deserialization.

The log confirms this on every failure — each NPE is preceded by the same handler thread logging:

```
1083930  DEBUG zookeeper.ZKOps: ... Could not read the contents of node
         /hbase/unassigned/1edc8893101fabdaabacd236d93e22ae since the node is absent
1083939  ERROR ... Handler died on an unexpected error, task M_RS_BRINGUP_REGION
1083940  java.lang.NullPointerException
```

The raw ZK wire trace at line 1083922 shows the `getData` reply for that node with error code `-101` (`NoNodeException`).

## The exact failure path

1. **`RegionBringupHandler.process` → `transitionZookeeperOfflineToOpening`** — `RegionBringupHandler.java:90` calls the transition helper; that helper at **`RegionBringupHandler.java:297`** calls `RegionStateZK.transitionNodeOpening(zkw, regionInfo, serverName)`.

2. **`RegionStateZK.transitionNodeOpening` (2-arg → 4-arg) → `transitionNode`** — `RegionStateZK.java:545` delegates to the 4-arg overload at `:552`, which calls `transitionNode(..., M_ZK_REGION_OFFLINE, RS_ZK_REGION_OPENING, -1)`.

3. **`RegionStateZK.transitionNode` reads the znode and unconditionally deserializes** — at `RegionStateZK.java:670-673`:
   ```java
   byte [] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);
   RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);
   ```
   There is **no `if (existingBytes == null)` branch** here — the value from `getDataNoWatch` is fed straight into `fromBytes`.

4. **`ZKOps.getDataNoWatch` returns `null` on `NoNodeException`** — `ZKOps.java:589-592`:
   ```java
   } catch (KeeperException.NoNodeException e) {
     LOG.debug(... "since the node is absent (not necessarily an error)");
     return null;
   }
   ```
   (also returns `null` for any other `KeeperException` at `:593-596` and for `InterruptedException` at `:597-600`.) This is the branch actually taken, matching the "node is absent" log line.

5. **`RegionStateRecord.fromBytes` forwards `null` into `SerdeUtil`** — `RegionStateRecord.java:195-203`:
   ```java
   public static RegionStateRecord fromBytes(byte [] bytes) {
     try {
       RegionStateRecord data = new RegionStateRecord();
       SerdeUtil.getWritable(bytes, data);   // line 198 — no null check on bytes
       ...
   ```

6. **`SerdeUtil.getWritable(byte[], Writable)` dereferences `bytes.length` before validating it** — `SerdeUtil.java:73-76`:
   ```java
   public static Writable getWritable(final byte [] bytes, final Writable w)
   throws IOException {
     return getWritable(bytes, 0, bytes.length, w);   // line 75 — NPE
   }
   ```
   `bytes.length` throws NPE because `bytes == null`. The null-guard exists **only in the 4-arg overload** at `SerdeUtil.java:95`:
   ```java
   if (bytes == null || length <=0) {
     throw new IllegalArgumentException("Can't build a writable with empty bytes array");
   }
   ```
   but control never reaches it — the `bytes.length` evaluation in the 2-arg wrapper happens first, so a `null` input becomes an NPE instead of the intended `IllegalArgumentException`.

## Which branches decide the failure

- `ZKOps.getDataNoWatch` takes the `NoNodeException` branch at `ZKOps.java:589` and returns `null`.
- `RegionStateZK.transitionNode` at `RegionStateZK.java:672-673` has no branch handling `existingBytes == null`; it always calls `RegionStateRecord.fromBytes(existingBytes)`.
- `RegionStateRecord.fromBytes` at `RegionStateRecord.java:198` has no branch handling `bytes == null`.
- `SerdeUtil.getWritable(byte[], Writable)` at `SerdeUtil.java:73-76` has no null-check; the only null-guard (`bytes == null || length <= 0`) is in the 4-arg overload at `SerdeUtil.java:95`, but is unreachable because `bytes.length` on line 75 is evaluated first.

The bug is the missing null handling on this path: when the OFFLINE znode a region server is asked to transition has already been deleted (or is otherwise unreadable), `getDataNoWatch`'s documented `null` return is fed straight into a deserializer whose 2-arg entry point calls `bytes.length` without a guard, killing the `M_RS_BRINGUP_REGION` handler instead of producing the intended "node existed but was in state X" / "expected version -1" negative return that the surrounding logic is designed to handle.
