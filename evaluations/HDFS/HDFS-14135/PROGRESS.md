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
| M3 | Reproduce and merge logs | PENDING | pending | null | — | — | 0 | — | — | — |
| M4 | Anonymize failure path | PENDING | pending | null | — | — | 0 | — | — | — |
| M5 | Prepare diagnosis inputs and ground truth | PENDING | pending | null | — | — | 0 | — | — | — |
| M6 | Run five diagnoses | PENDING | pending | null | — | — | 0 | — | — | — |
| M7 | Grade diagnoses | PENDING | pending | null | — | — | 0 | — | — | — |
| M8 | Summarize and finalize | PENDING | pending | null | — | — | 0 | — | — | — |

## Log

- 2026-08-18T01:44:58Z — M0 DONE: created and claimed `evaluations/HDFS/HDFS-14135/`; success=true.
- 2026-08-18T01:46:20Z — M1 IN_PROGRESS: researching the JIRA ticket and upstream fix history.
- 2026-08-18T01:55:49Z — M1 DONE: identified trunk fix `6b8107ad97251267253fa045ba03c4749f95f530` and pre-fix parent `b7fba78fb63a0971835db87292822fd8cd4aa7ad`; saved `private/fix.diff`; success=true.
- 2026-08-18T01:57:11Z — M2 IN_PROGRESS: checking out and building the pre-fix Hadoop HDFS source in Docker.
- 2026-08-18T02:16:31Z — M2 DONE: pre-fix tree builds from source (hadoop-hdfs jar + tests jar); protoc 2.5.0 supplied by the per-bug image; success=true.
