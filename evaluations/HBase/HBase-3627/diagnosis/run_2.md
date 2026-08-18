## Root cause

The NPE is a **missing null-check on the znode payload**. When the region-server tries to bring a region online, the unassigned znode `/hbase/unassigned/<encodedName>` does **not exist** in ZooKeeper (the log shows this: `Could not read the contents of node /hbase/unassigned/70236052 because node does not exist (not an error)`). The read returns `null`, and that `null` is fed through three layers without ever being checked, culminating in a NPE on `bytes.length`.

### The failure path (bottom-up from the stack)

1. **`RegionBringupHandler.transitionZookeeperOfflineToOpening` — `RegionBringupHandler.java:297`**
   Calls `RegionStateZK.transitionNodeOpening(zkw, regionInfo, serverName)` unconditionally, assuming the OFFLINE znode exists.

2. **`RegionStateZK.transitionNodeOpening` → `transitionNode` — `RegionStateZK.java:552` → `654`**
   No `Stat.exists()` pre-check. Goes directly to reading the node.

3. **`RegionStateZK.transitionNode` — `RegionStateZK.java:670-673`**
   ```java
   byte [] existingBytes = ZKOps.getDataNoWatch(zkw, node, stat);   // returns null if znode missing
   RegionStateRecord existingData = RegionStateRecord.fromBytes(existingBytes);  // <-- passes null through
   ```
   `ZKOps.getDataNoWatch` (`ZKOps.java:582-601`) explicitly `return null;` in the `NoNodeException` branch at line 589-592. The three "unassigned node for this region does not exist" bullets in the Javadoc at `RegionStateZK.java:525` are supposed to result in a `return -1`, but the code never implements that branch — the null goes straight into `fromBytes`.

4. **`RegionStateRecord.fromBytes` — `RegionStateRecord.java:195-203`**
   ```java
   public static RegionStateRecord fromBytes(byte [] bytes) {
     ...
     SerdeUtil.getWritable(bytes, data);   // line 198, passes null through
   ```
   No null guard on `bytes` — contrast with `SerdeUtil.getHRegionInfoOrNull` (`SerdeUtil.java:128-132`), which does have one.

5. **`SerdeUtil.getWritable(byte[], Writable)` — `SerdeUtil.java:73-76`**
   ```java
   public static Writable getWritable(final byte [] bytes, final Writable w) throws IOException {
     return getWritable(bytes, 0, bytes.length, w);   // line 75 — bytes.length dereferences null → NPE
   }
   ```
   The four-arg overload at line 92 *does* validate (`if (bytes == null || length <= 0) throw new IllegalArgumentException`), but the two-arg overload dereferences `bytes.length` **before** delegating, so the guard is never reached.

### Exact triggering branch

The failure fires exactly when both of these are true:

- `ZKOps.getDataNoWatch` hits the `catch (KeeperException.NoNodeException e) { … return null; }` branch at `ZKOps.java:589-592` (znode `/hbase/unassigned/<region>` absent — the log confirms this for region `70236052`).
- Control reaches `RegionStateZK.transitionNode` at line 673 without any prior `if (existingBytes == null) return -1;` check, so the `null` propagates through `RegionStateRecord.fromBytes` (`RegionStateRecord.java:198`) into `SerdeUtil.getWritable(byte[], Writable)`, whose `bytes.length` at `SerdeUtil.java:75` throws NPE.

### Fix location

The correct fix is in `RegionStateZK.transitionNode` (around line 672) — after reading `existingBytes`, add an `if (existingBytes == null) { LOG.warn(...); return -1; }`, matching the documented "unassigned node for this region does not exist → return -1" contract at lines 525-528. Defensively, `SerdeUtil.getWritable(byte[], Writable)` at line 75 should also null-check `bytes` before dereferencing `.length`, so this class of bug fails with `IllegalArgumentException` rather than NPE.
