## Root cause

The `getOtherUsedSpace` metric is an aggregate maintained in `HeartbeatManager.Stats.capacityUsedOther`, kept up-to-date by `stats.add(node)` / `stats.subtract(node)` calls that each read `node.getOtherUsed()` (the `otherUsed` field stored on the `DatanodeInfo`). The invariant it needs is that every `add` is paired with a `subtract` using the same value.

That invariant is broken in the **datanode re-registration** path when the datanode had previously been declared dead. The buggy sequence:

**1. Dead-node removal — `HeartbeatManager.removeDatanode` (HeartbeatManager.java:209-215)**

```java
synchronized void removeDatanode(DatanodeDescriptor node) {
  if (node.isAlive) {
    stats.subtract(node);          // capacityUsedOther -= node.getOtherUsed()  (say 1 MB)
    datanodes.remove(node);
    node.isAlive = false;          // <-- flag flipped, but otherUsed field on the descriptor is NOT cleared
  }
}
```

At this point `stats.capacityUsedOther` is correct, but `DatanodeDescriptor`/`DatanodeInfo.otherUsed` still holds the last reported value (1 MB). `removeDatanode` in `DatanodeManager` (DatanodeManager.java:543-554) does *not* call `wipeDatanode` for the dead-node path, so the same `DatanodeDescriptor` instance stays in `datanodeMap`.

**2. Re-registration — `DatanodeManager.registerDatanode` (DatanodeManager.java:871, 934)**

```java
DatanodeDescriptor nodeS = getDatanode(nodeReg.getDatanodeUuid());  // finds the stale descriptor
...
heartbeatManager.register(nodeS);                                    // line 934
```

**3. `HeartbeatManager.register` (HeartbeatManager.java:189-196) — the actual bug**

```java
synchronized void register(final DatanodeDescriptor d) {
  if (!d.isAlive) {                                        // TRUE  (we just marked it dead)
    addDatanode(d);                                        // stats.add(d)  <-- reads d.getOtherUsed() = 1 MB (STALE)
    d.updateHeartbeatState(StorageReport.EMPTY_ARRAY,
                           0L, 0L, 0, 0, null);            // only NOW is otherUsed reset to 0
  }
}
```

`addDatanode` at line 202-207 does `stats.add(d)`, and `Stats.add` at HeartbeatManager.java:407-409 executes:

```java
capacityUsedOther += node.getOtherUsed();   // adds the STALE 1 MB
```

The **stale value is added but was never subtracted a corresponding second time** — `subtract` at removal happened once and matched the earlier `add`; this `add` has no counterpart. The subsequent call to `updateHeartbeatState(EMPTY_ARRAY, …)` walks the empty `reports` loop (DatanodeDescriptor.java:416-428, `totalOtherUsed = 0`) and calls `setOtherUsed(0)` (line 436), which zeros the descriptor field *without* touching `stats`. So `capacityUsedOther` is now inflated by `otherUsed_at_death`.

**4. Subsequent normal heartbeats — `HeartbeatManager.updateHeartbeat` (HeartbeatManager.java:217-225)**

```java
stats.subtract(node);                    // subtracts 0 (field was zeroed in step 3)
node.updateHeartbeat(reports, …);        // setOtherUsed(realValue), e.g. 1 MB
stats.add(node);                         // adds the real 1 MB back
```

The delta from now on is correct, but the +1 MB spurious contribution from step 3 is permanently baked in.

## Match to the log

- `19:40:01,696` `DatanodeManager.removeDeadDatanode(586)` — `BLOCK* removeDeadDatanode: lost heartbeat from 127.0.0.1:44383` (the dying DN triggers step 1).
- `19:40:01,712` `DatanodeManager.removeDatanode(551)` — descriptor removed from `datanodes`/heartbeat but not wiped from `datanodeMap`; `otherUsed` still set on descriptor.
- `19:40:02,670` `DatanodeDescriptor.pruneStorageMap(452)` — `Number of storages reported in heartbeat=0; Number of storages in storageMap=1`. This is exactly the fingerprint of `register()` calling `updateHeartbeatState(StorageReport.EMPTY_ARRAY, …)` on a descriptor that still has one live storage entry from its previous incarnation — i.e. step 3 executed. Two other DNs (UUIDs `96d10ee7…` and `21838117…`) contribute the legitimate ~2 MB of "other used" observed in normal heartbeats; the leaked ~1 MB from the resurrected `127.0.0.1:44383` descriptor is what pushes `getOtherUsedSpace` to ~3 MB.

## The specific offending branch

- File `org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java`, method `register`, lines **189-196**: the `if (!d.isAlive)` branch calls `addDatanode(d)` *before* the descriptor's per-storage counters (including `otherUsed`) are reset by `updateHeartbeatState(StorageReport.EMPTY_ARRAY, …)`. Because `addDatanode` invokes `stats.add(d)` (line 204) → `Stats.add` line **409** `capacityUsedOther += node.getOtherUsed()`, the stale, never-subtracted `otherUsed` value from the previous life of the datanode is permanently added to `stats.capacityUsedOther`, which is what `FSNamesystem.getOtherUsedSpace` (FSNamesystem.java:6866-6868) returns via JMX.

Fix direction: reset `otherUsed` on the descriptor before calling `addDatanode(d)` (or reorder so `updateHeartbeatState(EMPTY_ARRAY, …)` runs first and then `addDatanode`), so `stats.add` sees a zeroed value consistent with the empty report.
