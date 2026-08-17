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
| M2 | Check out pre-fix, build from source, fix deps | DONE | true | success |
| M3 | Reproduce the failure + merge into production log | DONE | true | success |
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
- 2026-08-17T02:06Z M2 DONE success=true — `mvn -DskipTests -Dmaven.javadoc.skip=true package` on the pre-fix tree inside
  `clods-eval:HBase-HBase-3627` (base + `openjdk-8-jdk`, `JAVA_HOME` pinned to JDK 8 because the pom compiles `-source 1.6`).
  Artifacts: `target/hbase-0.90.2-SNAPSHOT.jar` + `-tests.jar`. Dep fixes: `private/install-deps.sh` installs the exact
  `hadoop-core-0.20-append-r1056497`, `avro-1.3.3` and `thrift-0.2.0` jars out of the `hbase-0.90.2.tar.gz` release tarball
  (their original repos — people.apache.org, repository.codehaus.org — are dead), plus Central's `hadoop-test-0.20.2.jar`
  under the append coordinate (test scope only); one source edit in `private/deps-fix.patch`
  (`InputSampler.java:320`, add a `(K[])` cast javac 8 requires and javac 6 did not).
- 2026-08-17T03:55Z M3 DONE success=true — real cluster (1 master + 3 regionservers + ZooKeeper, all DEBUG) built from the
  pre-fix tree in a `--cpus=2` container; 300-region table, 3M rows of 1 KB, mixed traffic; the incident is an operator
  **cluster restart**, after which the master re-places regions faster than the servers can open them. **7 181** regions-in-transition
  timeouts and **4 740** `Caught throwable while processing event M_RS_OPEN_REGION` + `NullPointerException` at
  `Writables.getWritable:75` ← `RegionTransitionData.fromBytes:198` ← `ZKAssign.transitionNode:673` ← … ←
  `OpenRegionHandler.process:90` ← `EventHandler.run:151`, each preceded by ZKUtil's `Unable to get data of znode … because
  node does not exist` — the JIRA's own trace. No source patched, no log line injected; detection is silent.
  `private/symptom.orig.log` = 1 662 415 lines / 244 MB (Log A); `private/merged.orig.log` = 13 657 242 lines / 3.3 GB
  (Log B = Log A merged into `production-logs/HBase/production.log`). Write-up in `reproduce.md`.
