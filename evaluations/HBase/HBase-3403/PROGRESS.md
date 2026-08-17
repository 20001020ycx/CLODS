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
| M4 | Anonymize failure path, rebuild, re-merge | DONE | true | success | 4 classes + 7 methods + 22 log literals; rebuilt, re-reproduced, re-merged; VERIFY OK |
| M5 | symptom.md + ground truth | DONE | true | success | bare-observable symptom; two-part ground-truth bar; VERIFY OK |
| M6 | LLM diagnosis ×5 | DONE | true | success | 5 single-turn runs, network locked, no follow-ups |
| M7 | Grade runs | DONE | true | success | 5/5 PASS on the two-part bar |
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
- 2026-08-17T02:39:57Z M4 DONE (success=true) — failure path anonymized, rebuilt, re-reproduced,
  re-merged, zero leakage. Replay: `bash private/anonymize.sh`; audit: `bash private/verify_anon.sh`.
  - **Failure path (completed causal chain, §6).** Traced end to end rather than taken as
    fix-diff ∪ stack-trace, because the symptom is a consistency report with no stack:
    `SplitTransaction` (commits the split) → `MetaEditor.offlineParentInMeta` (root cause) →
    `ServerManager.expireServer` (dispatcher, in neither discovery input) →
    `ServerShutdownHandler.process` → `MetaReader.getServerUserRegions` (the deciding branch)
    → `ServerShutdownHandler.processDeadRegion`/`fixupDaughters` (repair never reached) →
    `HBaseFsck.checkRegionConsistency` (symptom site).
  - **Renamed types/files:** `MetaEditor`→`CatalogWriter`, `MetaReader`→`CatalogScanner`,
    `ServerShutdownHandler`→`LostServerHandler`, `MetaServerShutdownHandler`→`MetaLostServerHandler`;
    in the test tree `TestSplitCrashRecovery`→`TestClusterWorkload` (its abort stack frame would
    otherwise name the scenario) and `TestMetaReaderEditor`→`TestCatalogReaderWriter`.
  - **Renamed distinctive methods:** `offlineParentInMeta`→`offlineSplitParent`,
    `fixupDaughters`/`fixupDaughter`→`recoverSplitChildren`/`recoverSplitChild`,
    `addDaughter`→`addSplitChild`, `getServerUserRegions`→`getRegionsOfServer`,
    `processDeadRegion`→`processLostRegion`.
  - **Rewritten log literals:** 22 in total — 7 in `CatalogWriter`, 9 in `LostServerHandler`,
    6 in `HBaseFsck` including both strings the JIRA report quotes
    ("… on HDFS, but not listed in META or deployed on any region server." and
    "Found inconsistency in table …").
  - **Deliberately kept generic:** `SplitTransaction`, `HBaseFsck`, `AssignmentManager`,
    `ServerManager`, `CatalogTracker`, `HRegionInfo`. `SplitTransaction`'s own log literals are
    kept byte-identical on purpose: HBase 1.2.7 emits exactly those strings throughout the
    shared production log, so rewriting them would make the reproduction stand out instead of
    blend in. Only `HBaseFsck`'s literals are rewritten, not its name (it is `hbck`, the
    generic operator tool).
  - **Regenerated from the anonymized tree:** `logs/repro.log` (7 414 lines) — the symptom
    still reproduces identically (assertion fires; `hbck` reports the region) — and
    `logs/symptom.log` (12 002 241 lines, 2.9 GB) = 7 361 anonymized reproduction records
    re-merged into the unchanged 11 945 370-record shared production log.
  - **Attempt 1 was discarded:** it leaked the bug id through *container paths* — the JVM's own
    log recorded `/work/repos/HBase-3403-anon/...` and `/work/repos/m2-HBase-3403/...` (147
    hits). Fixed by bind-mounting those two directories at the neutral container paths `/src`
    and `/m2`, so host directories keep their per-bug names while nothing the JVM logs carries
    the id. The whole M4 run was redone from scratch, not patched.
  - **Verification (`private/verify_anon.sh`, VERIFY OK):** every original class, method and log
    literal, and every case form of the bug id, = 0 across `source/`, `logs/repro.log`, the
    whole 2.9 GB `logs/symptom.log` and `symptom.md`; positive controls confirm the anonymized
    forms are present. **Documented exception:** the bare token `3403` occurs 183× in the
    *production* portion as genuine HBase/Hadoop/ZooKeeper RPC sequence numbers
    (`... sending #3403`, `header:: 3403,8`). The shared production log is read-only (§13) and
    those digits predate this bug's selection; the check asserts instead that no occurrence
    anywhere is ticket-shaped (`hbase|jira|issue|bug` + `3403` = 0).
  - `source/` is not kept as a separate git repo; it is regenerated deterministically by
    `private/anonymize.sh` from `pre_fix_commit` + `deps-fix.patch` + `repro-test.patch`
    (`anonymized_commit: null`).
- 2026-08-17T02:41:01Z M5 DONE (success=true) — diagnosis inputs + answer key.
  - `symptom.md` is the **bare observable**: one framing line, the two `ERROR:` lines exactly as
    `logs/symptom.log` prints them, and the merged-log pointer ("The log for this run is
    `logs/symptom.log`") — no `>>> SYMPTOM` marker and no line number, so the LLM has to grep
    the 2.9 GB log for the failure itself.
  - Anti-cheat re-read, sentence by sentence: it states **no** trigger (no split, no crash, no
    lost region server), no mechanism or timeline, no at-fault component/class/method/branch,
    no buggy overload or path, no "what stays correct" narrowing comparison, and no JIRA id.
  - `private/ground_truth.md` records (1) the root-causing line —
    `MetaEditor.offlineParentInMeta` lines 80–83 (anonymized `CatalogWriter.offlineSplitParent`)
    writing `SERVER_QUALIFIER`/`STARTCODE_QUALIFIER` as `EMPTY_BYTE_ARRAY`; (2) the deciding
    branch — `MetaReader.getServerUserRegions:578` (anonymized
    `CatalogScanner.getRegionsOfServer`) `pair.getSecond() == null || !…equals(hsi)` → `continue`,
    and the consequently unreached `processDeadRegion:179` `hri.isOffline() && hri.isSplit()` →
    `fixupDaughters`; plus the secondary fix hunks that are explicitly **not** the root cause and
    the two-part PASS bar (§8: both (a) and (b), no partial credit).
  - `private/verify_anon.sh` re-run with `symptom.md` in scope: **VERIFY OK** (all zero).
- 2026-08-17T13:01:38Z M6 DONE (success=true) — 5 independent single-turn diagnoses.
  - Subject pinned: `claude-opus-4-7`, `--effort high`, `--safe-mode --no-session-persistence
    --exclude-dynamic-system-prompt-sections --disallowed-tools Bash,Write,Edit,WebFetch,
    WebSearch,Task,NotebookEdit --permission-mode bypassPermissions`. **No follow-up prompts.**
  - Network: `iptables -P OUTPUT DROP` with a single ACCEPT to `api.anthropic.com:443`
    ("Network locked" confirmed at the head of the run log).
  - Isolation: staging held **only** `source/`, `symptom.md` and the hardlinked 3.0 GB
    `logs/symptom.log` — verified live inside the running container that `private/` was absent.
  - Harness deviation (same as the ZooKeeper bugs): `private/run_diagnosis.prodlog.sh` is
    `context/run_diagnosis.sh` with exactly two deltas — §5/M6's merged-log prompt text, and
    §7's hardlink-instead-of-copy staging. `context/` was not modified.
  - Auth deviation: this host has no `ANTHROPIC_API_KEY` (CCS manages OAuth), so a scratch copy
    of the credentials was mounted at `/root/.claude` with `CLAUDE_PURITY_FLAG=--safe-mode` and
    `IS_SANDBOX=1`, exactly as recorded for `Zookeeper-1900`. `TMPDIR=/stage` is a bind mount on
    the same filesystem as the bug dir so the merged log is hardlinked, not copied five times.
  - Run 5 required two retries for **infrastructure** reasons; both outputs were discarded
    without being graded and are not in `diagnosis/`: (1) `You've hit your session limit`
    (account rate limit), (2) `401 OAuth access token has been revoked` (the credential copy had
    rotated in the ~10 h since it was taken). After refreshing the credential copy the run
    completed normally. All five graded runs are complete single-turn answers; all five
    `run_N.stderr` are empty.
- 2026-08-17T13:02:29Z M7 DONE (success=true) — **5/5 PASS** against the two-part bar (§8: exact line *and* exact
  branch, no partial credit).
  - Every run named **(a)** `CatalogWriter.offlineSplitParent` writing `SERVER_QUALIFIER` /
    `STARTCODE_QUALIFIER` as `EMPTY_BYTE_ARRAY` at `CatalogWriter.java:80-83` — exactly the four
    lines the real fix deletes from `MetaEditor.offlineParentInMeta` — **and (b)** the deciding
    filter `pair.getSecond() == null || !pair.getSecond().equals(hsi)` → `continue` in
    `CatalogScanner.getRegionsOfServer:578` (real `MetaReader.getServerUserRegions`), together
    with the consequently unreachable `hri.isOffline() && hri.isSplit()` branch at
    `LostServerHandler.processLostRegion:179` that guards `recoverSplitChildren`.
  - Matching was by code identity (the anonymized line numbers happen to coincide with the
    pre-fix ones). Runs also corroborated the chain from the log itself — the master's
    `Re-hosting 1 region(s) last served by …` line, and the *absence* of any
    `Repairing; unrecorded split child` line.
  - No run was credited for the secondary fix hunks (`isDaughterMissing`, the
    `fullScan(startrow)` overload, the catalog-janitor test switch); none needed them.
