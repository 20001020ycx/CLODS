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
| M2 | Build from source at pre-fix | DONE | true | success | JDK 8 + hadoop 0.20.2 + thrift dropped; main & test compile |
| M3 | Reproduce + merge into production log | DONE | true | success | repro FAILs as intended; Log A 7 415 lines, Log B 3.06 GB merged |
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
- 2026-08-17T02:04:28Z M2 DONE (success=true) — pre-fix tree builds from source.
  - Image: `clods-eval:HBase-HBase-3403` = `clods-eval` + `openjdk-8-jdk` (JDK 8 is the newest
    JDK that still accepts `-source/-target 1.6`, which this pom pins via `compileSource`).
  - Build command:
    `mvn -B -s /work/repos/m2-HBase-3403/settings.xml -DskipTests test-compile`
    (run in the container with the repo mounted at `/work`, cwd `/work/repos/HBase-HBase-3403`).
  - Maven: 3.6.3 with a `settings.xml` that mirrors **all** repos to https Maven Central —
    the four repositories the 2011 pom lists (people.apache.org/~rawson, download.java.net,
    repository.codehaus.org, repository.jboss.org) are all dead. Local repo is kept per-bug at
    `repos/m2-HBase-3403/repository` so no other agent's build is affected.
  - Dependency fixes (`private/deps-fix.patch`):
    1. `hadoop.version` `0.20-append-r1056497` → `0.20.2`. The append artifact was published
       only to a temporary repo that no longer exists (404 on Central and repository.apache.org).
       `0.20.205.0` was tried first and fails: its security rewrite makes
       `UserGroupInformation` non-`Writable`, breaking `ipc/ConnectionHeader.java:63`.
       `0.20.2` compiles cleanly.
    2. Dropped the `org.apache.thrift:thrift:0.2.0` dependency and excluded `**/thrift/**`
       from compile and test-compile. That artifact survives in no reachable repo
       (Central 404, Cloudera 404). Nothing outside `org/apache/hadoop/hbase/thrift/`
       references thrift, and the thrift gateway is not on this bug's failure path.
    3. `InputSampler.java:320`: added an explicit `(K[])` cast. `inf` is a raw
       `InputFormat`, so the call erases to `Object[]`; javac 6 accepted it, javac 8 does not.
       Off the failure path, purely a toolchain-compat fix.
  - Result: `main` (467 sources) and the full test tree both compile; `MVN_EXIT=0`.
- 2026-08-17T02:15:37Z M3 DONE (success=true) — the bug reproduces on the pre-fix tree.
  - Test: `org.apache.hadoop.hbase.util.TestSplitCrashRecovery#testDaughterAfterServerCrash`
    (`private/repro-test.patch`). Split a `usertable` region on a 2-RS mini cluster, drop the
    daughter's `.META.` row (the crash window; upstream's own fix-test simulates it the same
    way), abort the region server, poll `.META.` for 180 s, then run the shipped `HBaseFsck`.
  - Verdict: FAIL as intended —
    `region usertable,,1786932488231.6751938fd298a88f2f50496c0afca9aa. is still absent from
    .META. 180s after the server that carried it was lost` (assertion goes to surefire's
    report file, not into the symptom log). `hbck` independently reports
    `Status: INCONSISTENT` / 2 inconsistencies in its own output.
  - Log A `private/symptom.orig.log`: 7 415 lines, the system's own DEBUG log4j + hbck output;
    no injected line anywhere (the test class logs nothing of its own; no probe added to
    production code).
  - Log B `private/merged.orig.log`: 12 002 242 lines / 3.06 GB — Log A retimed onto the
    production span (`2026-08-14 19:06:45,717 .. 19:31:38,751`, 11 945 370 records) and spread
    across all 20 per-host sections of the shared, unmodified
    `production-logs/HBase/production.log` by `private/merge_logs.py --interleave position`
    (Zookeeper-1851's tool, body copied unmodified). `position` rather than the spec's literal
    timestamp merge for the same reason as the ZooKeeper bugs: the production log is a bundle
    of per-host sections, not one sorted timeline.
  - Test-only infrastructure (all disclosed in `reproduce.md`): the test class itself;
    `hbase.catalogjanitor.interval=Integer.MAX_VALUE` (config, not code) so the janitor cannot
    delete the offlined parent mid-scenario; `src/test/resources/log4j.properties` raised to
    DEBUG with the production log's `%d %-5p [%t] %c: %m%n` layout (levels + layout only).
  - Write-up: `reproduce.md`.
