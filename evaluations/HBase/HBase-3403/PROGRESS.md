# HBase-3403 — milestone tracker

| Field | Value |
|---|---|
| bug id | HBase-3403 |
| system | HBase |
| jira | https://issues.apache.org/jira/browse/HBASE-3403 |
| source repo | https://github.com/apache/hbase.git |
| fix commit | _TBD (M1)_ |
| pre-fix commit | _TBD (M1)_ |
| agent | agent-run-8b54496c |

## Milestones

| ID | Milestone | Status | success | outcome | Note |
|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | true | success | folder + trackers created |
| M1 | Identify fix / pre-fix commit | PENDING | null | pending | |
| M2 | Build from source at pre-fix | PENDING | null | pending | |
| M3 | Reproduce + merge into production log | PENDING | null | pending | |
| M4 | Anonymize failure path, rebuild, re-merge | PENDING | null | pending | |
| M5 | symptom.md + ground truth | PENDING | null | pending | |
| M6 | LLM diagnosis ×5 | PENDING | null | pending | |
| M7 | Grade runs | PENDING | null | pending | |
| M8 | Summary & finalize | PENDING | null | pending | |

## Environment notes

- Shared production log: `production-logs/HBase/production.log` (3.06 GB) — present, so the
  M3 merge applies (no legacy standalone-log fallback).
- Scratch clone: `repos/HBase-HBase-3403` (gitignored).
- Other agents concurrently own `evaluations/HBase/HBase-4078` and `evaluations/HBase/HBase-3627`.

## Log

- 2026-08-17T01:53:55Z M0 IN_PROGRESS — created `evaluations/HBase/HBase-3403/` with
  `private/ source/ logs/ diagnosis/`.
- 2026-08-17T01:53:55Z M0 DONE (success=true) — PROGRESS.md + state.json written, bug claimed
  in `evaluations/COORDINATION.log`.
