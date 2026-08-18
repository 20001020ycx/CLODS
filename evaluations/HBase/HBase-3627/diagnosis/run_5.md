## Root cause

The region server fails because `RegionStateZK.transitionNode` never handles the case where the ZooKeeper unassigned znode does not exist.

### Failure path

1. `RegionBringupHandler.process` calls `transitionZookeeperOfflineToOpening(encodedName)` (`RegionBringupHandler.java:90`), which invokes `RegionStateZK.transitionNodeOpening(zkw, regionInfo, serverName)` (`RegionBringupHandler.java:297`).
2. That routes through the two overloads at `RegionStateZK.java:542-547` and `:549-554` into `transitionNode(...)` with `expectedVersion = -1` and `beginState = M_ZK_REGION_OFFLINE`.
3. Inside `transitionNode`, the node data is read at `RegionStateZK.java:670-671`:
   ```java
   byte [] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);
   RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);
   ```
   `ZKOps.getDataNoWatch` returns **null** when the znode does not exist (the log shows exactly this at line 2910: `Could not read the contents of node /hbase/unassigned/70236052 because node does not exist (not an error)`).
4. `RegionStateRecord.fromBytes(null)` (`RegionStateRecord.java:195-203`) calls `SerdeUtil.getWritable(bytes, data)` with `bytes == null`.
5. `SerdeUtil.getWritable(byte[], Writable)` at `SerdeUtil.java:73-76` immediately delegates:
   ```java
   public static Writable getWritable(final byte [] bytes, final Writable w) throws IOException {
     return getWritable(bytes, 0, bytes.length, w);   // <-- line 75: bytes.length NPEs when bytes==null
   }
   ```
   The two-argument overload never null-checks `bytes` — it dereferences `bytes.length` before calling the four-arg overload (whose own `bytes == null` guard at line 95 would have thrown `IllegalArgumentException`, but is never reached). The `NullPointerException` is thrown, propagates up through `fromBytes` → `transitionNode` → `transitionNodeOpening` → `RegionBringupHandler.transitionZookeeperOfflineToOpening` → `process`, and the `RS_REGION_BRINGUP` executor task dies.

### The specific missing branch

`RegionStateZK.transitionNode` is documented (`RegionStateZK.java:524-529`) to return `-1` when *"Unassigned node for this region does not exist"*, but that branch is never implemented. Between the read at line 671 and the `fromBytes` at line 673 there is no `if (existingBytes == null) return -1;` guard, so a missing znode is fed into deserialization instead of aborting the transition cleanly.

### The bug is one of two lines

- **`SerdeUtil.java:75`** — `bytes.length` is dereferenced with no null check, so a `null` input becomes an NPE instead of the `IllegalArgumentException` the four-arg overload documents.
- **`RegionStateZK.java:672-673`** — the caller does not check `existingBytes != null` before invoking `RegionStateRecord.fromBytes`, so a legitimately missing `/hbase/unassigned/<encodedName>` znode (a normal race during OFFLINE→OPENING when the master hasn't created / has already cleaned the node) crashes the bring-up handler instead of returning `-1` as designed. This is the true root cause; `SerdeUtil` merely converts the missing precondition into a less helpful exception type.
