## Root cause

`CapacityUsedOther` (the `@Metric` exposed at `FSNamesystem.java:4849–4852` via `getCapacityUsedOther()`) is nothing more than a running sum of every heartbeat's per‑storage `otherUsed` field. There is no cluster‑level (`total − dfsUsed − remaining`) reconciliation and no de‑duplication of physical disks. Given the deployment in the log — ~50 datanodes (172.25.0.3…0.42+, each with capacity ≈ 2.9 TB) that report the same underlying host filesystem's non‑DFS usage — the sum multiplies that single disk's other‑used bytes by the number of reporting DNs. That is why the metric is stuck around 1.1×10¹⁴ B (~110 TB), while `CapacityTotal` is only 147 TB and `CapacityUsed` is only 5–11 GB.

## The exact code path and branches

1. `DatanodeStorageInfo.java:287` (in `updateState`, called from `receivedHeartbeat` at :162):
   ```
   otherUsed = r.getOtherUsed();
   ```
   The per‑storage field is copied verbatim from the wire report — the NN does not recompute or dedupe.

2. `DatanodeDescriptor.java:363–436` (`updateHeartbeatState`):
   - Line 370: `long totalOtherUsed = 0;`
   - Line 416 – 428 (unconditional loop over **every** report in the heartbeat, no per‑disk dedupe):
     ```
     for (StorageReport report : reports) {
       …
       storage.receivedHeartbeat(report);
       …
       totalOtherUsed += report.getOtherUsed();   // line 427
     }
     ```
   - Line 436: `setOtherUsed(totalOtherUsed);` — stores the per‑DN sum on the `DatanodeInfo` base object (`DatanodeInfo.java:284–286`).

   So one DN with N storages on the same physical FS already accumulates N × the same “other” value here.

3. `HeartbeatManager.java` `Stats.add(node)` (lines 407–422) — called once per DN in the cluster:
   ```
   capacityUsed      += node.getDfsUsed();
   capacityUsedOther += node.getOtherUsed();      // line 409  — UNCONDITIONAL
   …
   if (!(node.isDecommissionInProgress() || node.isDecommissioned())) {
       …
       capacityTotal     += node.getCapacity();     // line 415 — GUARDED
       capacityRemaining += node.getRemaining();    // line 416 — GUARDED
   } else {
       capacityTotal += node.getDfsUsed();          // line 418
   }
   ```
   The critical branch behaviour: `capacityUsedOther` is added **outside** the decommission guard at line 412, while `capacityTotal`/`capacityRemaining` are inside it. That breaks the natural “Total − Used − Remaining ≈ Other” invariant that would otherwise catch the inflation, and it means every DN — including any decommissioning ones and any DN whose storages back onto shared disk — contributes its entire per‑DN `otherUsed` to the cluster metric.

   `Stats.subtract` at lines 424–439 mirrors the same asymmetry, so once the sum is inflated, subtraction cannot correct it either (it just decrements by whatever the current inflated per‑DN value is).

4. `HeartbeatManager.java:142–145`:
   ```
   public synchronized long getCapacityUsedOther() {
     return stats.capacityUsedOther;
   }
   ```
   returns the accumulated (inflated) sum with no post‑processing.

5. `FSNamesystem.java:4849–4852` (metric) and `:6866–6868` (MXBean `getOtherUsedSpace`) simply re‑publish `datanodeStatistics.getCapacityUsedOther()`.

## Why this produces the observed values

- Per‑DN reported `otherUsed` = (host filesystem capacity − this DN's dfsUsed − filesystem remaining) ≈ 2.3 TB (the shared host disk's non‑HDFS usage).
- Cluster sum in `Stats.add` line 409 ≈ (#DNs) × 2.3 TB ≈ 50 × 2.3 TB ≈ 115 TB — matching `CapacityUsedOther = 1.098×10¹⁴` at 23:26:30 and `1.123×10¹⁴` at 23:29:16 in `symptom.log:89776` and `:121401`.
- Meanwhile `CapacityTotal − CapacityRemaining − CapacityUsed = 147.5 TB − 30.2 TB − 5.6 GB ≈ 117 TB` — the *actual* aggregate non‑DFS space — is close to the inflated value only because each DN is separately over‑reporting the same underlying disk. The metric never divides by the number of DNs backed by the same physical volume, so the "other" bytes are counted once per DN rather than once per disk.

The failure path in one sentence: because `HeartbeatManager.Stats.add` (`HeartbeatManager.java:409`) unconditionally sums per‑DN `otherUsed`, and per‑DN `otherUsed` is itself an unconditional sum over storage reports (`DatanodeDescriptor.java:427` / `:436`, sourced from `DatanodeStorageInfo.java:287`), any deployment where multiple heartbeats describe the same physical storage inflates `CapacityUsedOther` (`FSNamesystem.java:4849/6866`) roughly N‑fold, exactly as seen in the log.
