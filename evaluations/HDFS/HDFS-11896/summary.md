# Summary — HDFS-11896

## Result
**Successes: 5 / 5**

| Run | Verdict | What it named |
|-----|---------|----------------|
| 1 | PASS | `resetBlocks()` omits `setOtherUsed(0)` + `register()` add-before-reset ordering; full 2X trace; cites real log lines. |
| 2 | PASS | Same, with an explicit per-step accounting table; cites `node restarted` at log L4468. |
| 3 | PASS | Both fix sites as "the two conditions that combine"; exact branches. |
| 4 | PASS | Both sites; "why only other-used is wrong" (others zeroed by `resetBlocks`). |
| 5 | PASS | Both sites; exact branch chain incl. `registerDatanode` restart path; cites L4315/L4468. |

## System / bug
- **System:** Apache Hadoop **HDFS** (identifiers kept per the minimal-anonymization policy).
- **Real bug:** HDFS-11896, "Non-dfsUsed will be doubled on dead node re-registration"
  (branch-2.7 pre-fix `b51623503fb`). Only the JIRA id was scrubbed and the metric
  `nonDfsUsed` renamed to `otherUsed`.

## How it was reproduced (integrity-corrected)
A MiniDFSCluster driver runs with **DEBUG logging on**, performs **real operations** (writes
and reads three files), then drives the dead → re-register cycle. **No log/print statements
are injected anywhere**; reproduction is detected by a silent JUnit assertion on the
NameNode's own metric (`expected 2097152` vs `observed 3145728` — doubled), and that
assertion output is **not** written into the symptom log. The symptom log the LLM sees is the
**real 4578-line NameNode/DataNode DEBUG trace** (3588 DEBUG + 888 INFO lines). The only thing
stated to the model beyond the log is the observable symptom in `symptom.md` (the metric reads
~3 MB when it should read ~2 MB) — legitimate because the metric is a JMX value not present in
any log line.

## Ground truth
The branch-2.7 fix changed two coupled locations (fixing either resolves it):
1. **`DatanodeDescriptor.resetBlocks()`** zeroes every node-level total **except** `otherUsed`
   (`nonDfsUsed`) — a dead node's descriptor keeps a stale value.
2. **`HeartbeatManager.register()`** (`if(!d.isAlive)` branch) calls `addDatanode(d)` →
   `stats.add(d)` → `capacityUsedOther += node.getOtherUsed()` (stale) **before**
   `updateHeartbeatState(EMPTY_ARRAY)` resets the field, with no compensating `stats.subtract`.
The stale value is baked into the running total and re-added by the next heartbeat → doubled.

## Discussion
Even after removing the earlier hand-holding (per-stage `PROBE` lines that had narrated the
mechanism) and giving the model only the **real DEBUG log** plus the observable symptom, the
LLM isolated the exact root-causing branch **deterministically — 5/5**, and this time **all
five** runs explicitly named *both* fix sites (`resetBlocks`'s missing `setOtherUsed(0)` and
the `register()` add-before-reset ordering), reconstructing the full three-step accounting
(death subtract → re-registration re-adds the stale value before the reset → next heartbeat
re-adds the true value) and citing the actual log lines (`removeDeadDatanode` at 4315,
`node restarted` at 4468). Notably, removing the injected breadcrumbs made the diagnoses *more*
rigorous, not less — the model had to reason from real events rather than pattern-match a probe
line. This is a case where a state-of-the-art LLM, given only real source and a real
reproduction log, reliably bypassed any deterministic tool for a single, well-localized
accounting bug. The caveat that remains is scope, not hinting: the failure path is small and
self-contained within one subsystem (`blockmanagement`) and the symptom is a clean, single-node
doubling. The result supports the thesis that LLMs can nail *some* localized bugs
deterministically; whether that holds for deep or cross-subsystem failures — where no such clean
trace exists — is what CLODS-style grounding is meant to address, and is what aggregating across
harder bugs will show.
