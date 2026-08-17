# HBase-4078 — milestone tracker

| Field | Value |
|---|---|
| bug id | HBase-4078 |
| system | HBase |
| jira | https://issues.apache.org/jira/browse/HBASE-4078 |
| source repo | https://github.com/apache/hbase.git |
| fix commit | _TBD (M1)_ |
| pre-fix commit | _TBD (M1)_ |
| owner | agent-run-4ee9c5a7 |

## Milestones

| ID | Milestone | Status | success | outcome | note |
|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | true | success | folder + trackers created |
| M1 | Identify fix + pre-fix commit | PENDING | null | pending | |
| M2 | Build from source at pre-fix | PENDING | null | pending | |
| M3 | Reproduce + merge into production log | PENDING | null | pending | |
| M4 | Anonymize failure path, rebuild, re-reproduce | PENDING | null | pending | |
| M5 | Diagnosis inputs + ground truth | PENDING | null | pending | |
| M6 | LLM diagnosis ×5 | PENDING | null | pending | |
| M7 | Grade runs | PENDING | null | pending | |
| M8 | Summary & finalize | PENDING | null | pending | |

## Log

- 2026-08-17T01:52:58Z agent-run-4ee9c5a7 — claimed HBase-4078; created `evaluations/HBase/HBase-4078/{private,source,logs,diagnosis}`; wrote PROGRESS.md + state.json. First HBase bug in this workspace (`production-logs/HBase/production.log` exists, 3.06 GB, HBase 1.2.7 under YCSB+chaos monkey — so the M3 merge applies).
