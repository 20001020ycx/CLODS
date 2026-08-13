# Summary — HDFS-11896 (production-log attempt)

A **separate** attempt using a **real 50-DataNode production log** as the symptom log, with the
same anonymized `source/` and the same bare-observable style `symptom.md`. It does not replace
the top-level minicluster result.

## Result
**Successes (identified HDFS-11896): 0 / 5.**

| Run | Verdict | What it concluded |
|-----|---------|-------------------|
| 1 | FAIL | Shared host FS; `otherUsed` summed N×; missed the dead/re-register event. |
| 2 | FAIL | ~50 DNs on one FS summed N×; `Stats.add` L409 outside decommission guard. |
| 3 | FAIL | ~30 DNs colocated; unconditional sums at `DatanodeDescriptor:427` + `HeartbeatManager:409`. |
| 4 | FAIL | 10-DN Docker-compose on one host disk; non-DFS counted N×. |
| 5 | FAIL | ~50 DNs on `/dev/sda2`; sum counts the shared disk once per DN. |

None named `resetBlocks()`, the `register()` add-before-reset ordering, or the `172.25.0.38`
dead→re-register event. **0/5 for the target bug.**

## What actually happened
The production log genuinely contains HDFS-11896: `172.25.0.38` dies at 23:27:34, re-registers
at 23:28:40, and `CapacityUsedOther` jumps `109.85 TB → 112.36 TB` (~+2.5 TB, that node's
other-used double-counted). But the **absolute** value of the metric (~110 TB) is dominated by a
**benign artifact**: this is a Docker-compose cluster of ~50 DataNode containers on a single
host, so every DN reports the same host filesystem's non-DFS bytes and the NameNode sums them
~N×. All five runs correctly reverse-engineered *that* (some even found `/dev/sda2` and did the
per-DN arithmetic) — and, having explained the "abnormally high" symptom I gave them, stopped.
None looked for a change *over time* or examined the death/re-registration events buried in the
152k-line log.

## Discussion
This is the most informative run so far, and it cuts against the earlier minicluster numbers.
On a controlled reproduction with a clean 4.5k-line log, the model (given the same bare symptom)
found a sufficient fix. On a **real** production log it went **0/5** on the target bug — for
three compounding reasons that are exactly what makes production diagnosis hard:
1. **Confounded symptom.** "Metric is abnormally high" had a dominant *benign* explanation (the
   containerized shared-FS N× summing). The model anchored on that and never separated it from
   the bug's smaller, transient signal.
2. **Needle in a haystack.** The decisive events — one `removeDeadDatanode` and one
   re-`registerDatanode` for `172.25.0.38`, and two metric samples 30k lines apart — are a
   handful of lines among 152,644. No run correlated the metric step with the node event.
3. **Plausible-cause anchoring.** The shared-FS story is internally coherent and log-supported,
   so the model committed to it without seeking a second explanation.

This is a clean argument for CLODS-style grounding: a deterministic tool that tracks *which
node's contribution changed when* would have pointed straight at the `172.25.0.38`
re-registration step that all five diagnoses missed. It also flags a methodology lesson — for a
metric whose absolute level is legitimately setup-dependent, the honest observable is the
*spurious change* (the ~2.5 TB step with no corresponding real usage change), not the absolute
magnitude. Re-running with that observable would be a fairer test of whether the LLM can find
the bug in production logs; as posed here, it did not (0/5).
