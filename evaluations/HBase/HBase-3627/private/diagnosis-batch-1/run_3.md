Confirmed. Here is the root cause.

## Root cause

The NPE is a null-`byte[]` dereference in `SerdeUtil.getWritable`, triggered when `RegionStateZK.transitionNode` reads an **absent** `/hbase/unassigned/<encodedName>` znode and passes the resulting `null` straight into deserialization.

## The failure path, line by line

1. `RegionBringupHandler.transitionZookeeperOfflineToOpening` (`RegionBringupHandler.java:297`) calls `RegionStateZK.transitionNodeOpening(...)`, which resolves through `RegionStateZK.java:545` → `RegionStateZK.java:552` into the private `transitionNode(...)`.

2. In `RegionStateZK.transitionNode` (`RegionStateZK.java:670-673`):
   ```java
   byte [] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);
   RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);
   ```
   `ZKOps.getDataNoWatch` (`ZKOps.java:582-602`) catches `KeeperException.NoNodeException` at line 589 and **returns `null`** (see log line 2910: `Could not read the contents of node /hbase/unassigned/70236052 because node does not exist (not an error)`). `existingBytes` is `null` and is passed through unchecked.

3. `RegionStateRecord.fromBytes` (`RegionStateRecord.java:195-203`) does not null-check `bytes`; it calls `SerdeUtil.getWritable(bytes, data)` at line 198 with `bytes == null`.

4. `SerdeUtil.getWritable(byte[], Writable)` (`SerdeUtil.java:73-76`):
   ```java
   public static Writable getWritable(final byte [] bytes, final Writable w)
   throws IOException {
     return getWritable(bytes, 0, bytes.length, w);   // line 75  <-- NPE
   }
   ```
   The two-arg overload dereferences `bytes.length` **before** delegating to the four-arg overload — so it throws `NullPointerException` on the argument evaluation. The null-guard that would have thrown `IllegalArgumentException` lives one layer deeper (`SerdeUtil.java:95`: `if (bytes == null || length <= 0)`), and is never reached.

## The exact logical conditions that produce the crash

The path is taken iff both branches below are simultaneously true during `M_RS_BRINGUP_REGION`:

- **Branch A — ZK read misses:** In `ZKOps.getDataNoWatch`, the `catch (KeeperException.NoNodeException e)` branch at `ZKOps.java:589` fires (znode `/hbase/unassigned/<encodedName>` does not exist at read time), causing the method to `return null` at line 592. This happens when the master has not yet created (or has already deleted) the unassigned znode for the region the RS is trying to open — a race between master OFFLINE-znode creation/cleanup and the RS bring-up handler.

- **Branch B — deserialization has no null guard on the wrapper overload:** In `SerdeUtil.java:73-76`, the two-argument `getWritable` immediately reads `bytes.length` without a null check, so the null returned from Branch A crashes here rather than being converted to the intended `IllegalArgumentException` in the four-argument overload (`SerdeUtil.java:95`).

Because `RegionStateRecord.fromBytes` (`RegionStateRecord.java:198`) rethrows any `IOException` as `RuntimeException` but does not handle `NullPointerException`, the NPE propagates up through `RegionStateZK.transitionNode` → `RegionBringupHandler.transitionZookeeperOfflineToOpening` → `RegionBringupHandler.process` → `TaskHandler.run`, killing the `M_RS_BRINGUP_REGION` task and preventing the region from ever being brought online — matching the reported symptom of region servers "repeatedly failing to bring regions online."

## Fix location

Either (or both):

- `SerdeUtil.java:73-76` — null-check `bytes` before `bytes.length` in the two-arg overload (mirror the guard at line 95).
- `RegionStateZK.java:670-673` — treat `existingBytes == null` (i.e., the unassigned znode is absent) as the documented "Unassigned node for this region does not exist" failure and `return -1` instead of feeding null into `RegionStateRecord.fromBytes`.

The most defensible fix is `RegionStateZK.transitionNode`, since its own Javadoc (`RegionStateZK.java:524-529`) already lists "Unassigned node for this region does not exist" as one of the three legitimate `-1` return conditions — it just forgot to actually check for it.
