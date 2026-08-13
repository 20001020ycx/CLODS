## Root Cause

The `CapacityUsedOther` metric is an accumulator that is fed straight from what each DataNode reports for a per-storage "other used" number. The value from each storage/DN is summed with no guard and no derivation from capacity/used/remaining. Because the five DataNodes in this cluster (`172.25.0.3`…`172.25.0.8`, all registered around log lines 1049‑1264) run against the same underlying host filesystem, every DN reports essentially the same non-DFS-used figure, and the NameNode faithfully sums them five times — producing an inflated ~110 TB.

Do the arithmetic from the log samples (e.g. line 89770‑89776):
- `CapacityTotal = 147,560,765,440,000` (~147.56 TB, i.e. 5 × ~29.5 TB — the same host FS reported per DN)
- `CapacityRemaining = 30,190,019,884,352` (~30.2 TB, likewise 5 × ~6 TB)
- `CapacityUsed = 5,594,601,803` (~5 GB of actual DFS data)
- `CapacityUsedOther = 109,853,041,161,909` (~109.85 TB ≈ 5 × ~22 TB non-DFS on the shared disk)

The per-DN value is roughly correct; the sum is not. The metric never gets computed as `capacityTotal − capacityUsed − capacityRemaining`; it is a raw accumulation of the DN-reported field.

## Exact code path / branches

1. Metric getter (source of the JMX value):
   - `FSNamesystem.getCapacityUsedOther()` — `source/.../namenode/FSNamesystem.java:4849-4853` — annotated `@Metric({"CapacityUsedOther", ...})`, delegates to `datanodeStatistics.getCapacityUsedOther()`.
   - `HeartbeatManager.getCapacityUsedOther()` — `source/.../blockmanagement/HeartbeatManager.java:143-145` — returns the cumulative field `stats.capacityUsedOther` (declared line 395).

2. How `stats.capacityUsedOther` is fed — the buggy accumulation:
   - `HeartbeatManager.Stats.add(node)` at `HeartbeatManager.java:407-422`. Line **409**:
     ```java
     capacityUsedOther += node.getOtherUsed();
     ```
     Note this line is **outside** the `if (!(node.isDecommissionInProgress() || node.isDecommissioned()))` branch at line 412 that guards `capacityTotal`/`capacityRemaining`. So `capacityUsedOther` is added for *every* node (in-service or decommissioned/decommissioning), while `capacityTotal` for decommissioned nodes only receives `getDfsUsed()`. That asymmetry alone lets `capacityUsedOther` grow past `capacityTotal`.
   - The symmetric decrement at line 426 in `Stats.subtract` is also unconditional — fine in isolation, but it never re-derives the value.

3. Where `node.getOtherUsed()` comes from — trust of the DN's number:
   - `DatanodeInfo.getOtherUsed()` — `source/.../protocol/DatanodeInfo.java:190-192` — returns the stored `otherUsed` field verbatim; it is *not* computed as `capacity − dfsUsed − remaining`.
   - The field is populated only once, at `DatanodeDescriptor.updateHeartbeatState`, `source/.../blockmanagement/DatanodeDescriptor.java:352-436`, specifically:
     - Line **427**: `totalOtherUsed += report.getOtherUsed();` — sums whatever the DN put in the storage report's `otherUsed` field over *all* `StorageReport`s that came in the heartbeat (even if several storages live on one physical filesystem).
     - Line **436**: `setOtherUsed(totalOtherUsed);` — writes that sum into `DatanodeInfo.otherUsed` unconditionally (no clamp, no check against `capacity − dfsUsed − remaining`).
   - `report.getOtherUsed()` is just a stored field on `StorageReport` (`source/.../server/protocol/StorageReport.java:28,61-63`); the value is whatever the DN put in the RPC. `DatanodeStorageInfo.updateState` (`DatanodeStorageInfo.java:284-290`, line 287) simply copies it: `otherUsed = r.getOtherUsed();`.

4. Feedback loop into the metric each heartbeat — `HeartbeatManager.updateHeartbeat` at `HeartbeatManager.java:217-225`:
   ```java
   stats.subtract(node);
   node.updateHeartbeat(reports, ...);   // rewrites node.otherUsed via lines 427/436
   stats.add(node);                      // executes line 409 with the new value
   ```
   Because `Stats.add` (line 409) is executed for every reporting DN with the raw sum from line 427, and there is *no* NN-side branch that reconciles the reported number against `capacity − dfsUsed − remaining`, the same underlying non-DFS bytes end up counted once per DataNode.

## The failing conditions, in one sentence

The reported `CapacityUsedOther` = `Σ_nodes ( Σ_storages report.getOtherUsed() )` — with the outer sum in `HeartbeatManager.Stats.add` (line 409) applied unconditionally (independent of the `!isDecommission…` branch on line 412), the inner sum in `DatanodeDescriptor.updateHeartbeatState` (line 427) done with no per-DN de-duplication, and `DatanodeInfo.getOtherUsed()` (line 190) returning the stored value rather than a derived one. When multiple DataNodes share the same physical filesystem (this cluster: five DNs, each reporting the host's ~22 TB non-DFS usage), the sum inflates to ~5× the true value, which is exactly what the JMX metric reports.
