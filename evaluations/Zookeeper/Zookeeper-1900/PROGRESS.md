# Zookeeper-1900 — milestone tracker

| field | value |
|---|---|
| bug id | `Zookeeper-1900` |
| system | Zookeeper |
| JIRA | https://issues.apache.org/jira/browse/ZOOKEEPER-1900 |
| source repo | https://github.com/apache/zookeeper.git |
| fix commit | `6abd85938f450587ec1c8973176261fb60a6838b` (trunk/3.5.0; branch-3.4 companion `8ff14a712`) |
| pre-fix commit | `8cfb9a0efa5c8934eb3c95ca69566c718a37d9ca` |
| agent | `agent-run-ea3110e6` |

Runbook: `context/METHODOLOGY.md`. This file and `state.json` are kept in sync; every
milestone carries `status` + `success` + `outcome`.

## Milestones

| ID | Milestone | Status | success | outcome |
|---|---|---|---|---|
| M0 | Scaffold & claim the bug folder | DONE | true | success |
| M1 | From JIRA: fix commit + pre-fix commit | DONE | true | success |
| M2 | Check out pre-fix, build from source, fix deps | PENDING | null | pending |
| M3 | Reproduce the failure | PENDING | null | pending |
| M4 | Anonymize, rebuild, re-confirm reproduction | PENDING | null | pending |
| M5 | Prepare diagnosis inputs & ground truth | PENDING | null | pending |
| M6 | Run LLM diagnosis x5 (network locked) | PENDING | null | pending |
| M7 | Grade each run vs ground truth | PENDING | null | pending |
| M8 | Write summary & finalize | PENDING | null | pending |

## Log

- 2026-08-12T17:42:49Z M0 IN_PROGRESS — created `evaluations/Zookeeper/Zookeeper-1900/` with `private/ source/ logs/ diagnosis/`, wrote `PROGRESS.md` + `state.json`, claimed the bug in `evaluations/COORDINATION.log`.
- 2026-08-12T17:44:30Z M0 DONE success=true — scaffold complete.
- 2026-08-12T17:58Z M1 DONE success=true — ZOOKEEPER-1900 "NullPointerException in truncate" (Blocker; affects 3.4.5/3.4.6, fixed in 3.4.7 + 3.5.0).
  Fix commit `6abd85938` (trunk, 2014-06-30) changes two production lines: a `if (input == null) throw new IOException(...)` guard in `FileTxnLog.truncate()`, and `catch (IOException e)` → `catch (Exception e)` in `Observer.observeLeader()`; it also adds `TruncateTest.testTruncationNullLog`. Pre-fix = `8cfb9a0ef`. Saved `private/fix.diff` (+ `private/fix.branch-3.4.diff`, which additionally widens the same catch in `Follower.java` — trunk's `Follower` already caught `Exception`, so on trunk only an **observer** exercises that second site).
