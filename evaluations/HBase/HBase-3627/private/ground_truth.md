# Ground truth — HBase-3627 (answer key; never shown to the diagnosis LLM)

Derived from `private/fix.diff` = branch-0.90 commit `79b522db0c8795d9d303aa6ec564c197b3a8bb20`
("HBASE-3627 NPE in EventHandler when region already reassigned", Michael Stack, 2011-03-24,
released in 0.90.2). Pre-fix tree = `86e9f5f8c9cb36b3dd2a1344c8c8c2bf95f44cc5`.
The trunk twin is `cf3284dfb9` (`private/fix.trunk.diff`), which makes the same two production
changes plus unrelated `CatalogTracker`/`MetaReader` edits. `23606d0645`
(`private/fix.addendum.diff`) reuses the ticket id for an unrelated `LeaseException` catch and is
**not** part of this fix.

## Name translation (anonymization map)

| real (pre-fix tree) | anonymized (`source/`) |
|---|---|
| `zookeeper/ZKAssign.java` → `ZKAssign` | `zookeeper/RegionStateZK.java` → `RegionStateZK` |
| `zookeeper/ZKUtil.java` → `ZKUtil` | `zookeeper/ZKOps.java` → `ZKOps` |
| `executor/RegionTransitionData.java` → `RegionTransitionData` | `executor/RegionStateRecord.java` → `RegionStateRecord` |
| `util/Writables.java` → `Writables` | `util/SerdeUtil.java` → `SerdeUtil` |
| `executor/EventHandler.java` → `EventHandler` | `executor/TaskHandler.java` → `TaskHandler` |
| `regionserver/handler/OpenRegionHandler.java` → `OpenRegionHandler` | `regionserver/handler/RegionBringupHandler.java` → `RegionBringupHandler` |
| `master/AssignmentManager.java` → `AssignmentManager` | `master/RegionPlacementManager.java` → `RegionPlacementManager` |
| `master/handler/OpenedRegionHandler.java` → `OpenedRegionHandler` | `master/handler/RegionOnlineHandler.java` → `RegionOnlineHandler` |
| event `M_RS_OPEN_REGION` / executor `RS_OPEN_REGION` | `M_RS_BRINGUP_REGION` / `RS_REGION_BRINGUP` |

Full map incl. the rewritten log literals: `private/anon-map-source.json` (source) and
`private/anon-map-production.json` (the subset applied to the production-noise stream).

## The two production-code sites the fix changed

### Site A — the root cause on the reproduced failure path

**Real:** `src/main/java/org/apache/hadoop/hbase/zookeeper/ZKAssign.java`,
`transitionNode(ZooKeeperWatcher, HRegionInfo, String, EventType, EventType, int)`,
**pre-fix lines 669-673** (the read at 670-671, the unguarded deserialization at 672-673)
**Anonymized:** `source/java/org/apache/hadoop/hbase/zookeeper/RegionStateZK.java`,
`transitionNode(...)`, **lines 669-673** — identical line numbers, the anonymization is a pure rename.

```java
    // Read existing data of the node
    Stat stat = new Stat();
    byte [] existingBytes =
      ZKUtil.getDataNoWatch(zkw, node, stat);        // returns null when the znode is gone
    RegionTransitionData existingData =
      RegionTransitionData.fromBytes(existingBytes); // <-- dereferences null
```

**The missing branch (what the fix adds, immediately after the read):**

```java
    if (existingBytes == null) {
      // Node no longer exists.  Return -1. It means unsuccessful transition.
      return -1;
    }
```

**The exact condition:** `existingBytes == null`, i.e. `ZKUtil.getDataNoWatch` returned `null`
because the unassigned znode `/hbase/unassigned/<encodedRegionName>` **no longer exists** (it
catches `KeeperException.NoNodeException`, logs "Unable to get data of znode … because node does
not exist (not necessarily an error)" and returns `null`). `transitionNode` uses that value
unconditionally, so `RegionTransitionData.fromBytes(null)` →
`Writables.getWritable(bytes, w)` → `bytes.length` → `NullPointerException`
(`Writables.java:75`; the null check lives only in the 4-argument overload, which is reached
*after* the dereference). The NPE is unchecked, so it escapes
`OpenRegionHandler.transitionZookeeperOfflineToOpening`'s `catch (KeeperException e)` (and
`tickleOpening`'s), unwinds out of `OpenRegionHandler.process`, and is caught by
`EventHandler.run`'s `catch (Throwable t)`, which logs
"Caught throwable while processing event M_RS_OPEN_REGION".

A run must name **this line** (the unguarded `ZKUtil.getDataNoWatch` result being passed to
`RegionTransitionData.fromBytes` in `ZKAssign.transitionNode`) **and** the missing
`existingBytes == null` guard / the znode-deleted condition that makes it null.

Credit-neutral context (naming it neither helps nor hurts): `Writables.getWritable`'s early
`bytes.length`, `ZKUtil.getDataNoWatch`'s `NoNodeException → null`, `EventHandler.run`'s
`catch (Throwable)`, and the assignment race that deletes the znode (the master re-places a
region that is still queued for open on the first server; when the second server finishes the
open, `OpenedRegionHandler` deletes the unassigned node).

### Site B — the same defect on the master side (not on the reproduced path)

**Real:** `src/main/java/org/apache/hadoop/hbase/master/AssignmentManager.java`, inner class
`TimeoutMonitor`, `case OPENING:` branch: the read at **pre-fix lines 1644-1645** and its
unguarded dereference at **line 1646**.
**Anonymized:** `source/java/org/apache/hadoop/hbase/master/RegionPlacementManager.java`,
`TimeoutMonitor`, `case OPENING:` — same line numbers (read at 1644-1645, dereference at 1646).

```java
                  RegionTransitionData data = ZKAssign.getDataNoWatch(watcher, node, stat);
                  if (data.getEventType() == EventType.RS_ZK_REGION_OPENED) {   // <-- null deref
```

**The missing branch (what the fix adds):**

```java
                  if (data == null) {
                    LOG.warn("Data is null, node " + node + " no longer exists");
                    break;
                  }
```

**The exact condition:** `data == null`, i.e. `ZKAssign.getDataNoWatch` returned `null` because
the unassigned znode of a region the master is timing out in state `OPENING` has already been
deleted.

**This site is NOT exercised by the reproduction** (verified on the final M4 run: 7 203
regions-in-transition timeouts, every one of them `PENDING_OPEN`; zero
"Region has been claimed for too long" (= "has been OPENING for too long") lines and zero
`NullPointerException`s in the master log). It is therefore invisible in `logs/symptom.log`.

### Non-behavioural parts of the fix (never required)

`OpenRegionHandler.process` gains a `LOG.warn("Region was hijacked? …")` on the existing
early-return; `private HRegion openRegion()` becomes package-private (a test hook);
`ZKAssign.getData`/`getDataNoWatch` and `ZKUtil.getDataNoWatch` javadoc is corrected; a new
`TestOpenRegionHandler` is added.

## Grading bars (pre-registered before M6)

* **PRIMARY (headline verdict, METHODOLOGY §10 "the fix touches multiple files … a run must name
  all to PASS"):** the answer names **both** Site A and Site B, each with its exact null-check
  branch.
* **AUXILIARY (on-path bar, reported alongside):** the answer names **Site A** with its exact
  branch condition. This is the only site the symptom log can testify to, so this number is the
  fair measure of the reasoning task; both numbers go into every `run_N.grade.json`, into
  `state.json.result` and into `summary.md`.
* No partial credit within a site: right file but wrong line = FAIL; right line without the
  null-ness condition = FAIL; hedged answers with no concrete line = FAIL. Line numbers may be
  quoted from `source/` (they coincide with the pre-fix tree's).
