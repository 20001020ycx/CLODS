# Zookeeper-1900 — milestone tracker

| field | value |
|---|---|
| bug id | `Zookeeper-1900` |
| system | Zookeeper |
| JIRA | https://issues.apache.org/jira/browse/ZOOKEEPER-1900 |
| source repo | https://github.com/apache/zookeeper.git |
| fix commit | _TBD (M1)_ |
| pre-fix commit | _TBD (M1)_ |
| agent | `agent-run-ea3110e6` |

Runbook: `context/METHODOLOGY.md`. This file and `state.json` are kept in sync; every
milestone carries `status` + `success` + `outcome`.

## Milestones

| ID | Milestone | Status | success | outcome |
|---|---|---|---|---|
| M0 | Scaffold & claim the bug folder | DONE | true | success |
| M1 | From JIRA: fix commit + pre-fix commit | PENDING | null | pending |
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
