# Zookeeper-1434 — milestone tracker

- **System:** Zookeeper
- **JIRA:** ZOOKEEPER-1434 (https://issues.apache.org/jira/browse/ZOOKEEPER-1434)
- **Owner:** agent-run-57ce8ccf
- **Source repo:** https://github.com/apache/zookeeper.git
- **Fix commit:** `7f64942ba8e5ce00948f6e7b23271de0556b668f` (trunk, 2011-05-16, fixVersion 3.4.0)
- **Pre-fix commit:** `59ac9fa78963ca746d21a62a27fde497fd4c4d58`
- **Symptom (short):** the zkCli shell dies with an unhandled `NullPointerException` when the
  node-status command is issued on a path that does not exist.

## Commit derivation (M1)

ZOOKEEPER-1434 ("zkCli crashes with NPE on stat of non-existent path", affects 3.3.5) is
`Resolved / Won't Fix`: the committer declined a 3.3 backport because HBase depended on the
3.3 behaviour **and the same defect was already fixed on trunk/3.4 by ZOOKEEPER-1059**
(identical symptom and identical stack trace). The commit whose diff resolves the reported
defect is therefore `7f64942ba` — it adds the missing `stat == null` guard in
`ZooKeeperMain.processZKCmd`. The 3.3-branch patch attached to ZOOKEEPER-1434 itself
(`private/jira-1434-attached-3.3-patch.diff`) is byte-for-byte the same change, which
confirms the two tickets share one root cause. The pre-fix tree used for the whole
evaluation is `59ac9fa78` (trunk @ 2011-05, 3.4.0-dev), where the `stat` branch calls
`printStat(zk.exists(...))` unguarded.

## Milestones

| ID | Milestone | Status | success | outcome | Note |
|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | true | success | folder + trackers created |
| M1 | Identify fix / pre-fix commit | DONE | true | success | fix=7f64942ba (ZOOKEEPER-1059), pre=59ac9fa78 |
| M2 | Build from source at pre-fix | PENDING | null | pending | |
| M3 | Reproduce the failure | PENDING | null | pending | |
| M4 | Anonymize + re-confirm | PENDING | null | pending | |
| M5 | Diagnosis inputs & ground truth | PENDING | null | pending | |
| M6 | LLM diagnosis ×5 (network locked) | PENDING | null | pending | |
| M7 | Grade runs | PENDING | null | pending | |
| M8 | Summary & finalize | PENDING | null | pending | |

## Log

- 2026-08-11T20:40:31Z — M0 DONE (success). Created `evaluations/Zookeeper/Zookeeper-1434/`
  with `private/`, `source/`, `logs/`, `diagnosis/`; wrote `PROGRESS.md` + `state.json`;
  claimed the bug in `evaluations/COORDINATION.log`.
- 2026-08-11T20:55:00Z — M1 DONE (success). Fix commit 7f64942ba / pre-fix 59ac9fa78 identified
  from the ticket (via its Won't-Fix rationale pointing at ZOOKEEPER-1059); saved
  `private/fix.diff` and the ticket's own 3.3 patch attachment.
