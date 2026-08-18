## Root Cause

The region server crashes because `transitionNode` in `RegionStateZK` never checks whether the ZK unassigned-node contents actually exist before parsing them, and the `SerdeUtil.getWritable(byte[], Writable)` overload has no null-guard, so a missing znode is fed straight into a `bytes.length` dereference.

### The exact code path

1. **`RegionBringupHandler.transitionZookeeperOfflineToOpening`** (`RegionBringupHandler.java:296-298`) calls
   `RegionStateZK.transitionNodeOpening(zk, regionInfo, serverName)`.

2. **`RegionStateZK.transitionNodeOpening(...)`** (`RegionStateZK.java:542-554`) delegates to
   `transitionNode(zkw, region, serverName, M_ZK_REGION_OFFLINE, RS_ZK_REGION_OPENING, -1)`.

3. **`RegionStateZK.transitionNode`** (`RegionStateZK.java:670-673`) reads the znode:
   ```java
   byte [] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);
   RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);
   ```
   There is **no `existingBytes == null` guard** here, even though the Javadoc (lines 524–528) explicitly says the method must return `-1` when "unassigned node for this region does not exist".

4. **`ZKOps.getDataNoWatch`** (`ZKOps.java:582-602`) catches `KeeperException.NoNodeException` at line 589 and **returns `null`**. That is exactly the branch that fires here — grep of the log shows:
   ```
   19:08:00,802 ... Could not read the contents of node
     /hbase/unassigned/70236052 because node does not exist (not an error)
   ```
   The OFFLINE znode that the master was supposed to have pre-created for the region is absent when the RS tries to claim it.

5. **`RegionStateRecord.fromBytes(null)`** (`RegionStateRecord.java:195-203`) forwards the `null` bytes into
   `SerdeUtil.getWritable(bytes, data)` at line 198 without validation.

6. **`SerdeUtil.getWritable(byte[], Writable)` — the 2-arg overload** (`SerdeUtil.java:73-76`):
   ```java
   public static Writable getWritable(final byte [] bytes, final Writable w)
     throws IOException {
     return getWritable(bytes, 0, bytes.length, w);   // line 75 — NPE here
   }
   ```
   It dereferences `bytes.length` **before** delegating to the 4-arg overload. The 4-arg overload at lines 95-101 *does* null/empty-check (`if (bytes == null || length <= 0)`), but that check is never reached — the NPE happens one frame earlier evaluating the length argument.

### The failing logical condition

The bug is a missing branch, in two places, either of which would have prevented the crash:

- **`RegionStateZK.transitionNode` (line 672-673)** should short-circuit when `existingBytes == null` (return `-1`, matching the Javadoc's "Unassigned node for this region does not exist" case). Instead it unconditionally calls `RegionStateRecord.fromBytes(existingBytes)`.
- **`SerdeUtil.getWritable(byte[], Writable)` (line 75)** should either null-check `bytes` itself or route through a form that doesn't touch `bytes.length` on the caller's frame. The null-check lives only in the 4-arg overload, so callers using the 2-arg entry point bypass it.

### Trigger in this run

Between `19:08:00.802` (RS reads `/hbase/unassigned/70236052` and finds it absent) and `19:08:06.048` (master finally creates the OFFLINE znode for region `70236052`), the region server executes `M_RS_BRINGUP_REGION` for `-ROOT-,,0.70236052` and hits `transitionNode` while the znode is still missing. The result is the observed NPE cascade at `SerdeUtil.java:75`, killing every subsequent `RS_REGION_BRINGUP` task on `hbase-node-a`.
