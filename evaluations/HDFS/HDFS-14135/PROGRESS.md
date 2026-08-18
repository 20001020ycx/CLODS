# HDFS-14135 evaluation progress

- **System:** HDFS
- **JIRA:** https://issues.apache.org/jira/browse/HDFS-14135
- **Owner:** `agent-run-53a0adfb`

## Milestones

| ID | Milestone | Status | Outcome | Success | Started | Finished | Attempts | By | Artifacts | Note |
|---|---|---|---|---|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | success | true | 2026-08-18T01:44:58Z | 2026-08-18T01:44:58Z | 1 | agent-run-53a0adfb | `PROGRESS.md`, `state.json` | Created and claimed the per-bug evaluation workspace. |
| M1 | Identify fix and pre-fix commits | DONE | success | true | 2026-08-18T01:46:20Z | 2026-08-18T01:55:49Z | 1 | agent-run-53a0adfb | `private/fix.diff` | Trunk fix `6b8107ad97251267253fa045ba03c4749f95f530`; pre-fix parent `b7fba78fb63a0971835db87292822fd8cd4aa7ad`. The diff waits for socket-backlog saturation and conditionally skips timeout assertions when saturation cannot be established. |
| M2 | Build pre-fix source | DONE | success | true | 2026-08-18T01:57:11Z | 2026-08-18T02:16:31Z | 1 | agent-run-53a0adfb | `private/deps-fix.patch`, `private/Dockerfile`, `reproduce.sh` | `mvn -pl hadoop-hdfs-project/hadoop-hdfs -am package -DskipTests -DskipITs -Dcheckstyle.skip -Drat.skip -Dmaven.javadoc.skip=true` on JDK 11 / Maven 3.6.3; BUILD SUCCESS. Sole dependency fix is toolchain-level: protobuf 2.5.0 compiler built from source (`private/Dockerfile`); no pom edits. |
| M3 | Reproduce and merge logs | DONE | success | true | 2026-08-18T02:33:42Z | 2026-08-18T02:33:42Z | 1 | agent-run-53a0adfb | `reproduce.sh`, `reproduce.md`, `private/symptom.orig.log`, `private/merged.orig.log`, `private/repro/*`, `private/merge_logs.py` | Intermittent reproduction (1 of 3 suite repetitions failed; 1 of its 16 checks) under 2 ms loopback latency, alongside real MiniDFSCluster WebHDFS traffic. Log A 17,990 lines; Log B 49,711,986 lines = 26,323,996 production + 15,244 reproduction records. |
| M4 | Anonymize failure path | DONE | success | true | 2026-08-18T02:34:23Z | 2026-08-18T02:51:06Z | 2 | agent-run-53a0adfb | `source/`, `logs/repro.log`, `logs/symptom.log`, `private/anonymization_map.json`, `private/anonymize.sh`, `private/anon_map_build.py`, `private/verify_anon.sh` | Test file/type, helper, constants, test-method names renamed and failure-path literals rewritten; rebuilt and re-reproduced (3/3 repetitions failed, 7 checks). `source/` = 319 java files, anon commit `71f580f`. Logs regenerated from the anonymized tree: repro.log 18,467 lines, symptom.log 49,712,463 lines. Leakage verification all clean. |
| M5 | Prepare diagnosis inputs and ground truth | DONE | success | true | 2026-08-18T02:51:21Z | 2026-08-18T02:51:56Z | 1 | agent-run-53a0adfb | `symptom.md`, `private/ground_truth.md` | Bare observable (the pasted AssertionError) + log pointer, 42 words, no cause/trigger/mechanism; answer key lists the fix's exact lines and both branch conditions in real and anonymized names. |
| M6 | Run five diagnoses | DONE | success | true | 2026-08-18T02:52:07Z | 2026-08-18T03:07:11Z | 1 | agent-run-53a0adfb | `diagnosis/run_1..5.md`, `private/run_diagnosis.prodlog.sh`, `private/m6-run.sh`, `private/m6-harness.log` | 5 fresh single-turn runs, Opus 4.7 effort high via the ccs anthropic subscription account, egress locked to api.anthropic.com:443; all exited 0 with empty stderr; no follow-ups. |
| M7 | Grade diagnoses | DONE | success | true | 2026-08-18T03:07:23Z | 2026-08-18T03:08:19Z | 1 | agent-run-53a0adfb | `diagnosis/run_1..5.grade.json` | 5 PASS / 0 FAIL. Every run named the helper body (pre-fix 355-362) and the failing catch/assert branch; runs 3 and 4 carry a recorded caveat about an incorrect kernel-level explanation. |
| M8 | Summarize and finalize | PENDING | pending | null | — | — | 0 | — | — | — |

## Log

- 2026-08-18T01:44:58Z — M0 DONE: created and claimed `evaluations/HDFS/HDFS-14135/`; success=true.
- 2026-08-18T01:46:20Z — M1 IN_PROGRESS: researching the JIRA ticket and upstream fix history.
- 2026-08-18T01:55:49Z — M1 DONE: identified trunk fix `6b8107ad97251267253fa045ba03c4749f95f530` and pre-fix parent `b7fba78fb63a0971835db87292822fd8cd4aa7ad`; saved `private/fix.diff`; success=true.
- 2026-08-18T01:57:11Z — M2 IN_PROGRESS: checking out and building the pre-fix Hadoop HDFS source in Docker.
- 2026-08-18T02:16:31Z — M2 DONE: pre-fix tree builds from source (hadoop-hdfs jar + tests jar); protoc 2.5.0 supplied by the per-bug image; success=true.
- 2026-08-18T02:33:42Z — M3 DONE: failure reproduced and merged into the shared HDFS production log; success=true.
- 2026-08-18T02:34:23Z — M4 IN_PROGRESS: applying the anonymization map, rebuilding and re-reproducing from the renamed tree. (`reproduce.sh` also gained an explicit hdfs-client classpath entry so the tree under test wins over the M2 jars in ~/.m2.)
- 2026-08-18T02:51:06Z — M4 DONE: attempt 1 discarded (the build tree's bug-id-bearing path leaked into the log through Jetty's webapp resource paths); rebuilt in `repos/hadoop-webhdfs-build`, re-reproduced, re-merged and verified clean; success=true.
- 2026-08-18T02:51:56Z — M5 DONE: symptom.md and private/ground_truth.md written and gated (no bug id, no original identifiers, no cause leak); success=true.
- 2026-08-18T03:07:11Z — M6 DONE: 5 network-locked diagnoses written to `diagnosis/`; success=true.
- 2026-08-18T03:08:19Z — M7 DONE: all five runs graded against `private/ground_truth.md` (5 PASS); success=true.
