# Summary — HDFS-11896

## Result
**Successes: 5 / 5**

| Run | Verdict | What it named |
|-----|---------|----------------|
| 1 | PASS | `resetBlocks()` omits `setOtherUsed(0)` **and** `register()` `if(!d.isAlive)` add-before-reset ordering; full arithmetic. |
| 2 | PASS | `register()` add-before-reset ordering (exact branch) + complete stale/double-count mechanism; notes death path leaves the field stale. |
| 3 | PASS | `resetBlocks()` omits `setOtherUsed(0)` **and** `register()` add-before-reset ordering; full arithmetic. |
| 4 | PASS | `register()` ordering (exact branch) + mechanism + contrast with the fresh-node path; death path leaves the field stale. |
| 5 | PASS | `register()` ordering (exact branch) + mechanism + exact controlling branches (`registerDatanode` restart path). |

## System / bug
- **System:** Apache Hadoop **HDFS** (identifiers kept per the minimal-anonymization policy).
- **Real bug:** HDFS-11896, "Non-dfsUsed will be doubled on dead node re-registration"
  (branch-2.7 pre-fix `b51623503fb`). Only the JIRA id was scrubbed and the metric
  `nonDfsUsed` renamed to `otherUsed`.

## Symptom
The NameNode's cluster-wide *other-used* space metric (`getOtherUsedSpace`) is **doubled**
for a DataNode that dies and then re-registers: with two DNs each reporting 5000, the
metric reads **15000** instead of **10000**. No error is logged.

## Ground truth
The branch-2.7 fix changed two coupled locations (fixing either resolves it):
1. **`DatanodeDescriptor.resetBlocks()`** zeroes every node-level total **except**
   `otherUsed` (`nonDfsUsed`) — so a dead node's descriptor keeps a stale value.
2. **`HeartbeatManager.register()`** (`if(!d.isAlive)` branch) calls `addDatanode(d)` —
   which does `stats.add(d)` → `capacityUsedOther += node.getOtherUsed()` (stale) — **before**
   `updateHeartbeatState(EMPTY_ARRAY)` resets the field, with no compensating `stats.subtract`.
The stale value is thus baked into the running total and is re-added by the next real
heartbeat → doubled.

## Discussion
The LLM isolated the exact root-causing branch **deterministically — 5/5**. Every run
reconstructed the full three-step failure path (death subtract → re-registration
`addDatanode` re-adds the stale value before the reset → next heartbeat re-adds the true
value) and tied it precisely to the log arithmetic (`10000 → 5000 → 15000`), naming the
controlling `if(!d.isAlive)` branch and the add-before-reset ordering in `HeartbeatManager`.
Runs 1 and 3 additionally pinpointed `resetBlocks()`'s missing `setOtherUsed(0)` (the
canonical fix), while runs 2, 4, and 5 pinpointed the `register()` add-before-reset ordering
(the other half of the branch-2.7 fix) — both are real fix locations, so all five are correct
and actionable. This is a case where a state-of-the-art LLM, given only the (real, deanonymized-
metric) source and a real reproduction log, **reliably** bypassed any deterministic tool for a
single, well-localized accounting bug. Two caveats temper how far this generalizes: (a) the
symptom log here is unusually informative — the reproduction's `PROBE` lines expose the exact
per-stage metric values (`5000`/`15000`), handing the model the arithmetic to anchor on; and
(b) the failure path is small and self-contained within one subsystem (`blockmanagement`).
The result supports the thesis that LLMs can nail *some* localized bugs deterministically,
but says little about deep or cross-subsystem failures where such a clean symptom trace is
absent — exactly where CLODS-style grounding is expected to matter. Aggregating across
harder bugs will show whether this 5/5 reliability holds or degrades.
