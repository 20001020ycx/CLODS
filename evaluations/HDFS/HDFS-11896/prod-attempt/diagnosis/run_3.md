## Root Cause

The `CapacityUsedOther` metric is computed by naively **summing each DataNode's `otherUsed` across all DataNodes** in the cluster — with no de‑duplication for the fact that many DataNodes in this deployment are colocated on the **same physical filesystem** (the log shows ~30 DNs at 172.25.0.3…33, all on the same host). Each DN observes the *same* non‑DFS bytes on that shared disk and reports them; the NameNode adds them all together.

Numerical corroboration in `logs/symptom.log` (line 89770 ff.):
- `CapacityTotal      = 147,560,765,440,000` (≈147 TB)
- `CapacityUsed       = 5,594,601,803`      (≈5 GB, real DFS use)
- `CapacityRemaining  = 30,190,019,884,352` (≈30 TB)
- `CapacityUsedOther  = 109,853,041,161,909` (≈110 TB)

51 "Adding a new node" lines → ~30 DNs. If each DN sees a physical volume of ≈4.9 TB whose non‑DFS occupancy is ≈3.6 TB, we get `30 × 4.9 TB ≈ 147 TB` (matches `CapacityTotal`) and `30 × 3.6 TB ≈ 108 TB` (matches `CapacityUsedOther`). Both metrics are inflated by the same replication factor — the DN count.

## Exact code path that produces the failure

The metric is exposed here:

`source/org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java:4849‑4853`
```
@Metric({"CapacityUsedOther",
    "Total space used by data nodes for other purposes in bytes"})
public long getCapacityUsedOther() {
  return datanodeStatistics.getCapacityUsedOther();
}
```

Which delegates to `HeartbeatManager`:

`source/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java:143‑145`
```
public synchronized long getCapacityUsedOther() {
  return stats.capacityUsedOther;
}
```

`stats.capacityUsedOther` is maintained by `Stats.add()` / `Stats.subtract()`. The offending accumulation is:

`source/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java:407‑422` (the `add` method)
```
private void add(final DatanodeDescriptor node) {
  capacityUsed      += node.getDfsUsed();
  capacityUsedOther += node.getOtherUsed();      // <-- line 409: unconditional per-DN sum
  blockPoolUsed     += node.getBlockPoolUsed();
  xceiverCount      += node.getXceiverCount();
  if (!(node.isDecommissionInProgress() || node.isDecommissioned())) {
      nodesInService++;
      nodesInServiceXceiverCount += node.getXceiverCount();
      capacityTotal     += node.getCapacity();
      capacityRemaining += node.getRemaining();
  } else {
      capacityTotal    += node.getDfsUsed();
  }
  ...
}
```
Symmetric line at 426 in `subtract()`. Note that line 409 is **outside** the `if (!(node.isDecommissionInProgress() || node.isDecommissioned())) { ... }` branch — every DN's `otherUsed`, from every heartbeat/register/decommission transition, contributes to `capacityUsedOther`, regardless of state and regardless of whether other DNs already contributed the same physical bytes.

The per‑DN `node.getOtherUsed()` value comes from `DatanodeDescriptor.updateHeartbeatState`:

`source/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeDescriptor.java:416‑436`
```
for (StorageReport report : reports) {
  DatanodeStorageInfo storage = updateStorage(report.getStorage());
  if (checkFailedStorages) {
      failedStorageInfos.remove(storage);
  }
  storage.receivedHeartbeat(report);
  totalCapacity     += report.getCapacity();
  totalRemaining    += report.getRemaining();
  totalBlockPoolUsed+= report.getBlockPoolUsed();
  totalDfsUsed      += report.getDfsUsed();
  totalOtherUsed    += report.getOtherUsed();      // <-- line 427: sum across storages
}
...
setOtherUsed(totalOtherUsed);                       // <-- line 436
```
The loop body has no branch that filters or normalises `report.getOtherUsed()`; every storage report's value is added verbatim. The value being added is a `capacity − remaining − dfsUsed` snapshot of a physical filesystem (materialised into `DatanodeStorageInfo.otherUsed` at `DatanodeStorageInfo.java:287` — `otherUsed = r.getOtherUsed();`).

## The logical failure condition, stated precisely

For every DN heartbeat processed by `HeartbeatManager.updateHeartbeat` (`HeartbeatManager.java:217‑225` → `stats.subtract(node); node.updateHeartbeat(...); stats.add(node);`):

1. `DatanodeDescriptor.updateHeartbeatState` unconditionally executes `totalOtherUsed += report.getOtherUsed()` for every `StorageReport` in the heartbeat (DatanodeDescriptor.java:427). No branch guards this against reports pointing at a shared/overlapping filesystem.
2. `HeartbeatManager.Stats.add` unconditionally executes `capacityUsedOther += node.getOtherUsed()` before entering the decommission/in‑service `if` (HeartbeatManager.java:409). The `if (!(node.isDecommissionInProgress() || node.isDecommissioned()))` branch only gates `capacityTotal` / `capacityRemaining`; it does **not** gate — and no branch anywhere gates — the "other used" accumulation against duplication.
3. `FSNamesystem.getCapacityUsedOther()` (FSNamesystem.java:4851) reports that sum verbatim via JMX.

Because those two accumulation sites (DatanodeDescriptor.java:427 and HeartbeatManager.java:409) are both unconditional sums with no "same underlying volume" branch, when N DNs are colocated on one physical disk the metric is multiplied by N — which is exactly what the log values show.
