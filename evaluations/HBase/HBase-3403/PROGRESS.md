# HBase-3403 — milestone tracker

| Field | Value |
|---|---|
| bug id | HBase-3403 |
| system | HBase |
| jira | https://issues.apache.org/jira/browse/HBASE-3403 |
| source repo | https://github.com/apache/hbase.git |
| fix commit | `0d31ac5f37a2e8866884bb216a3485eea652a822` (trunk, svn r1056884) |
| pre-fix commit | `dddee0d50ff77c93a2b39f408bf11f60e397ebf4` |
| agent | agent-run-8b54496c |

## Milestones

| ID | Milestone | Status | success | outcome | Note |
|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | true | success | folder + trackers created |
| M1 | Identify fix / pre-fix commit | DONE | true | success | fix `0d31ac5f37`, pre-fix `dddee0d50f`, `private/fix.diff` saved |
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
- 2026-08-17T01:58:29Z M1 IN_PROGRESS — read JIRA HBASE-3403 (description + all comments via the
  ASF JIRA REST API) and cloned `apache/hbase` to `repos/HBase-HBase-3403`.
- 2026-08-17T01:58:29Z M1 DONE (success=true) — fix commit `0d31ac5f37a2e8866884bb216a3485eea652a822`
  ("HBASE-3403 Region orphaned after failure during split", trunk svn r1056884, 2011-01-09);
  pre-fix `dddee0d50ff77c93a2b39f408bf11f60e397ebf4`. Diff saved to `private/fix.diff`.
  Failure path traced in the pre-fix tree:
  `MetaEditor.offlineParentInMeta` blanks the parent's `SERVER`/`STARTCODE` in `.META.` at split
  commit → `MetaReader.getServerUserRegions` skips the parent (`pair.getSecond() == null`
  branch) when the master enumerates the dead server's regions →
  `ServerShutdownHandler.process`/`processDeadRegion` never reaches the
  `hri.isOffline() && hri.isSplit()` branch for the parent → `fixupDaughters` never runs →
  a daughter that never made it into `.META.` stays orphaned on HDFS.
