## Root cause

The `CapacityUsedOther` metric is a *plain sum-across-datanodes* of a value that every datanode independently reports for the **same underlying host filesystem**. On this cluster the ~50 datanodes are Docker containers that all sit on top of a single host volume (see `/dev/sda2` in `symptom.log:12260`, plus the arithmetic below), so the identical "non‑DFS used" figure is counted once per DN instead of once for the disk. That is why the metric reads 109–112 TB while the disk itself holds ~2 TB of non‑DFS data.

## Numeric check from the log (symptom.log:89770–89776)

```
CapacityTotal      = 147,560,765,440,000  (~147.5 TB total  ⇒ 2.95 TB / DN × 50)
CapacityRemaining  =  30,190,019,884,352  (~30.2 TB         ⇒ 600 GB  / DN × 50)
CapacityUsed       =       5,594,601,803  (~5.6 GB, real DFS content)
CapacityUsedOther  = 109,853,041,161,909  (≈ Total − Remaining − Used)
```
`CapacityUsedOther ≈ CapacityTotal − CapacityRemaining − CapacityUsed`, i.e. every DN reports `otherUsed ≈ capacity − dfsUsed − remaining` for its shared /dev/sda2, and the NN adds those 50 identical values together.

## Failure path in the source code

1. Per‑datanode aggregation of the storage reports  
   `source/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeDescriptor.java`
   - Line 370: `long totalOtherUsed = 0;`
   - Line 416–428: the `for (StorageReport report : reports)` loop
   - **Line 427: `totalOtherUsed += report.getOtherUsed();`** — sums across storages with no dedup by underlying filesystem
   - Line 436: `setOtherUsed(totalOtherUsed);` — stashes the per‑node total on the `DatanodeDescriptor`

2. Cluster‑wide aggregation in HeartbeatManager  
   `source/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java`
   - Line 395: `private long capacityUsedOther = 0L;`
   - `Stats.add(DatanodeDescriptor)`:
     - **Line 409: `capacityUsedOther += node.getOtherUsed();`** — added *unconditionally*, before the `if (!(node.isDecommissionInProgress() || node.isDecommissioned()))` guard on line 412, so it's counted for every node in `datanodes[]` regardless of admin state or whether the node is on a shared volume
   - `Stats.subtract(...)`: symmetric `-=` on line 426
   - Getter used by the metric: **line 143–145 `getCapacityUsedOther() { return stats.capacityUsedOther; }`**

3. Exposure of the value as a metric / JMX attribute  
   `source/org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java`
   - **Line 4849–4853** (`@Metric({"CapacityUsedOther", …}) public long getCapacityUsedOther() { return datanodeStatistics.getCapacityUsedOther(); }`) — the JMX/metrics entry point
   - Line 6865–6868 (`getOtherUsedSpace()`) — same value via `NameNodeMXBean`

## The exact logical conditions that cause the inflation

- In `Stats.add` / `Stats.subtract` (HeartbeatManager.java:407–439) the accumulation of `capacityUsedOther` happens on **every** call path that touches `stats`:
  - `updateHeartbeat` (line 217–225): `subtract → node.updateHeartbeat → add` on every heartbeat
  - `addDatanode` / `removeDatanode` (line 202–215): full add/subtract on join/leave
  - `startDecommission` / `stopDecommission` (line 227–248): also subtract/add
  - The `+=`/`-=` on lines 409/426 is **outside** the `if (!(node.isDecommissionInProgress() || node.isDecommissioned()))` branch on lines 412/429, so it's always executed — no filtering by admin state or by shared storage.
- In `DatanodeDescriptor.updateHeartbeatState` (DatanodeDescriptor.java:363–444), the loop at 416‑428 simply adds `report.getOtherUsed()` for each `StorageReport`, with no attempt to detect that multiple reports belong to the same physical volume. The only branch inside the loop (`if (checkFailedStorages) { failedStorageInfos.remove(storage); }` at 418‑420) is about failed‑storage tracking and does not affect the sum.

Because both aggregation layers use unconditional `+=` on a value the datanode derives per‑volume as `capacity − dfsUsed − remaining`, any deployment where several storages or several DNs share one filesystem (this Docker cluster, DNs with multiple data.dirs on one mount, etc.) will report `CapacityUsedOther` inflated by roughly the sharing factor (~50× here). The specific lines to point at are **DatanodeDescriptor.java:427** and **HeartbeatManager.java:409** (with the ancillary getter at HeartbeatManager.java:143–145 and metric definition at FSNamesystem.java:4849–4853).
