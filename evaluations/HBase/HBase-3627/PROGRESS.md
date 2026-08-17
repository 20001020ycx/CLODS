# HBase-3627 — milestone tracker

| field | value |
|---|---|
| bug id | `HBase-3627` |
| system | HBase |
| JIRA | https://issues.apache.org/jira/browse/HBASE-3627 |
| source repo | https://github.com/apache/hbase.git |
| fix commit | _TBD (M1)_ |
| pre-fix commit | _TBD (M1)_ |
| agent | `agent-run-4ee9c5a7` |

Runbook: `context/METHODOLOGY.md`. This file and `state.json` are kept in sync; every
milestone carries `status` + `success` + `outcome`.

## Milestones

| ID | Milestone | Status | success | outcome |
|---|---|---|---|---|
| M0 | Scaffold & claim the bug folder | DONE | true | success |
| M1 | From JIRA: fix commit + pre-fix commit | PENDING | null | pending |
| M2 | Check out pre-fix, build from source, fix deps | PENDING | null | pending |
| M3 | Reproduce the failure + merge into production log | PENDING | null | pending |
| M4 | Anonymize, rebuild, re-confirm reproduction | PENDING | null | pending |
| M5 | Prepare diagnosis inputs & ground truth | PENDING | null | pending |
| M6 | Run LLM diagnosis x5 (network locked) | PENDING | null | pending |
| M7 | Grade each run vs ground truth | PENDING | null | pending |
| M8 | Write summary & finalize | PENDING | null | pending |

## Log

- 2026-08-17T01:53:25Z M0 IN_PROGRESS — created `evaluations/HBase/HBase-3627/` with `private/ source/ logs/ diagnosis/`, wrote `PROGRESS.md` + `state.json`, claiming the bug in `evaluations/COORDINATION.log`.
- 2026-08-17T01:53:55Z M0 DONE success=true — scaffold complete; claimed in `evaluations/COORDINATION.log`.
