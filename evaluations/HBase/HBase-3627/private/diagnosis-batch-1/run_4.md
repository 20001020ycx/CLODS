## Root cause

The region server crashes because a missing (or unreadable) `/hbase/unassigned/<region>` znode is fed as `null` into a serializer that dereferences the byte array without a null check.

### The failure path

1. **`RegionBringupHandler.process` → `transitionZookeeperOfflineToOpening`** (RegionBringupHandler.java:90 → :297) calls `RegionStateZK.transitionNodeOpening(...)`.

2. **`RegionStateZK.transitionNode`** (`RegionStateZK.java:654-673`) reads the current znode contents:
   ```java
   byte [] existingBytes =
       ZKOps.getDataNoWatch(zkw, node, stat);       // line 670-671
   RegionStateRecord existingData =
       RegionStateRecord.fromBytes(existingBytes);  // line 672-673
   ```
   Nothing checks whether `existingBytes` is `null` before it is handed off.

3. **`ZKOps.getDataNoWatch`** (`ZKOps.java:582-602`) intentionally returns `null` in three branches:
   - `catch (KeeperException.NoNodeException e) { … return null; }` (line 589-592) – the znode does not exist.
   - `catch (KeeperException e) { … return null; }` (line 593-596)
   - `catch (InterruptedException e) { … return null; }` (line 597-600)
   
   The log confirms exactly this branch firing before the NPE, e.g. line 2910: `Could not read the contents of node /hbase/unassigned/70236052 because node does not exist (not an error)`. The unassigned znode for the region being brought up is absent, so `existingBytes == null`.

4. **`RegionStateRecord.fromBytes(null)`** (`RegionStateRecord.java:195-203`) blindly forwards to the serializer:
   ```java
   RegionStateRecord data = new RegionStateRecord();
   SerdeUtil.getWritable(bytes, data);              // line 198, bytes == null
   ```

5. **`SerdeUtil.getWritable(byte[], Writable)`** (`SerdeUtil.java:73-76`) is the actual NPE site:
   ```java
   public static Writable getWritable(final byte [] bytes, final Writable w)
   throws IOException {
     return getWritable(bytes, 0, bytes.length, w);   // line 75 – bytes.length on null
   }
   ```
   Note that only the *three-arg* overload at lines 92-101 guards against `bytes == null` (it would throw `IllegalArgumentException`). The two-arg overload dereferences `bytes.length` *before* delegating, so a `null` argument produces an unchecked `NullPointerException` instead of the intended `IllegalArgumentException`.

6. The NPE escapes `fromBytes` (its `catch` only handles `IOException`, not `RuntimeException`), propagates through `transitionNodeOpening` → `RegionBringupHandler.process`, and finally `TaskHandler.run` logs *"Handler died on an unexpected error, task M_RS_BRINGUP_REGION"* and terminates the handler. Because every subsequent bring-up attempt hits the same missing/unreadable znode, the region-server never brings any region online.

### The exact bug

Two cooperating defects on the failure path:

- **`SerdeUtil.getWritable(byte[], Writable)` at `SerdeUtil.java:73-76`** – dispatches `bytes.length` without null-checking `bytes`, so the null-guard in the delegate (`SerdeUtil.java:95`) is unreachable via this overload.
- **`RegionStateZK.transitionNode` at `RegionStateZK.java:670-673`** – treats the `null` return from `ZKOps.getDataNoWatch` (documented outcome for `NoNodeException` and other ZK failures) as if it were valid data, instead of returning `-1` the way the surrounding "node does not exist / wrong state / wrong version" branches (`RegionStateZK.java:676-693`) already do for the analogous conditions.

Either fix (null-check in `SerdeUtil.getWritable` at line 75, or a `if (existingBytes == null) return -1;` in `RegionStateZK.transitionNode` right after line 671) would break the failure path; both are appropriate, since the caller currently violates the callee's implicit precondition and the callee silently violates its own explicit precondition.
