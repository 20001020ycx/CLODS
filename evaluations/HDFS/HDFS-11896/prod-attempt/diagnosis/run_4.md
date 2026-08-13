## Root cause

The NameNode faithfully sums the `otherUsed` bytes that each DataNode reports for each of its storage volumes, without any awareness that multiple DataNodes can be sitting on the same physical filesystem. In this cluster all 10 DataNodes have `172.25.0.X` addresses (a Docker‑compose deployment) and therefore share the container host's disk. Every DN's `df` call sees the *same* pool of non‑HDFS bytes and reports it as its own `otherUsed`, so the NN adds that same number N times.

Numerically:
- `CapacityTotal = 147,560,765,440,000` (~14.7 TB × 10 DNs, i.e. the host disk counted 10×)
- `CapacityRemaining = 30,190,019,884,352` (~3 TB × 10, i.e. the host's free space counted 10×)
- `CapacityUsedOther = 109,853,041,161,909` (~11 TB × 10, i.e. the host's non‑HDFS usage counted 10×)

That is why the number is "inflated well beyond the actual non‑service disk usage" — the actual per‑host "other" is ≈11 TB, but the metric reports ~110 TB.

## The exact code path

1. **Per‑volume value coming in from the heartbeat** — `DatanodeStorageInfo.updateState`
   `source/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeStorageInfo.java:284‑290`
   ```java
   void updateState(StorageReport r) {
     capacity = r.getCapacity();
     dfsUsed = r.getDfsUsed();
     otherUsed = r.getOtherUsed();   // line 287 — taken verbatim from the DN
     remaining = r.getRemaining();
     blockPoolUsed = r.getBlockPoolUsed();
   }
   ```

2. **Per‑DN aggregation across volumes** — `DatanodeDescriptor.updateHeartbeatState`
   `source/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeDescriptor.java:416‑436`
   ```java
   for (StorageReport report : reports) {
     ...
     totalOtherUsed += report.getOtherUsed();     // line 427 — no dedup across volumes
   }
   ...
   setOtherUsed(totalOtherUsed);                  // line 436
   ```
   The loop has no branch/guard that skips or de‑duplicates reports that describe the same underlying physical volume; every element is added.

3. **Cluster‑wide aggregation across DNs** — `HeartbeatManager.Stats.add` / `subtract`
   `source/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java:407‑439`
   ```java
   private void add(final DatanodeDescriptor node) {
     capacityUsed      += node.getDfsUsed();
     capacityUsedOther += node.getOtherUsed();    // line 409 — UNCONDITIONAL
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
   Note the critical branch structure: `capacityUsedOther +=` is *outside* the `if (!(isDecommissionInProgress || isDecommissioned))` guard and outside any "same host / same filesystem" check. It is added for **every** heartbeating DN, once per DN — which is precisely what produces the N‑fold inflation when several DNs share a filesystem. `subtract()` mirrors this at line 426.

4. **Exposure to JMX** — `HeartbeatManager.getCapacityUsedOther`
   `source/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java:142‑145`
   ```java
   public synchronized long getCapacityUsedOther() {
     return stats.capacityUsedOther;
   }
   ```
   And `FSNamesystem.java:4849‑4853`:
   ```java
   @Metric({"CapacityUsedOther",
       "Total space used by data nodes for other purposes in bytes"})
   public long getCapacityUsedOther() {
     return datanodeStatistics.getCapacityUsedOther();
   }
   ```
   This is the value observed in `logs/symptom.log` (e.g. line 89776 `CapacityUsedOther = 109853041161909`).

## The failure condition (branches that must all hold)

The metric goes wrong whenever **all** of the following are true — which is the situation in this run:

- `reports.length ≥ 1` on entry to `DatanodeDescriptor.updateHeartbeatState`, so the loop at line 416‑428 executes and `totalOtherUsed` is accumulated (line 427) and then written back to the descriptor at line 436.
- `HeartbeatManager.updateHeartbeat` (line 217‑225) calls the `stats.subtract(node); node.updateHeartbeat(...); stats.add(node);` sandwich, so `Stats.add` (line 407) runs and hits the unconditional `capacityUsedOther += node.getOtherUsed();` at line 409 — the branch guard `if (!(node.isDecommissionInProgress() || node.isDecommissioned()))` is *not* wrapped around this statement.
- Multiple `DatanodeDescriptor`s exist (the 10 registrations at log lines 1049, 1064, 1081, 1100, 1150, 1264, 1298, 1334, …) whose underlying volumes physically share the container host's filesystem. Each of them independently reports the same host‑level "other used" bytes in `StorageReport.getOtherUsed()`, so the loop over `datanodes` in `Stats.add` sums the same underlying value once per DN.

There is no branch anywhere in `DatanodeDescriptor.updateHeartbeatState`, `DatanodeStorageInfo.updateState`, or `HeartbeatManager.Stats.add`/`subtract` that reconciles per‑volume/per‑DN `otherUsed` values against a shared physical device, so the NN‑side aggregation silently multiplies the true "other used" by the number of DNs sharing storage — producing the ~110 TB metric seen in the log.
