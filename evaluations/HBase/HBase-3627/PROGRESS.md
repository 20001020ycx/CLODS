# HBase-3627 — milestone tracker

| field | value |
|---|---|
| bug id | `HBase-3627` |
| system | HBase |
| JIRA | https://issues.apache.org/jira/browse/HBASE-3627 |
| source repo | https://github.com/apache/hbase.git |
| fix commit | `79b522db0c8795d9d303aa6ec564c197b3a8bb20` (branch-0.90, released in 0.90.2; trunk twin `cf3284dfb9`) |
| pre-fix commit | `86e9f5f8c9cb36b3dd2a1344c8c8c2bf95f44cc5` |
| agent | `agent-run-4ee9c5a7` |

Runbook: `context/METHODOLOGY.md`. This file and `state.json` are kept in sync; every
milestone carries `status` + `success` + `outcome`.

## Milestones

| ID | Milestone | Status | success | outcome |
|---|---|---|---|---|
| M0 | Scaffold & claim the bug folder | DONE | true | success |
| M1 | From JIRA: fix commit + pre-fix commit | DONE | true | success |
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
- 2026-08-17T01:58:41Z M1 DONE success=true — HBASE-3627 "NPE in EventHandler when region already reassigned" (Critical; affects 0.90.1, fixed in 0.90.2).
  Fix commit `79b522db0c` (branch-0.90, 2011-03-24) adds a null guard on the znode data read in `ZKAssign.transitionNode`
  (`if (existingBytes == null) return -1;` before `RegionTransitionData.fromBytes(existingBytes)`) and a second null guard in
  `AssignmentManager`'s TimeoutMonitor `OPENING` case; the `OpenRegionHandler` LOG.warn and the javadoc edits are non-behavioural.
  Pre-fix = `86e9f5f8c9`. Saved `private/fix.diff` (+ `private/fix.trunk.diff` = trunk twin `cf3284dfb9`, and
  `private/fix.addendum.diff` = `23606d0645`, a later same-titled commit that only widens a LeaseException catch — unrelated).
