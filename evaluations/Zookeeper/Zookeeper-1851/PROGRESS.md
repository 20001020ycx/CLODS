# Zookeeper-1851 — milestone tracker

| field | value |
|---|---|
| bug id | `Zookeeper-1851` |
| system | Zookeeper |
| JIRA | https://issues.apache.org/jira/browse/ZOOKEEPER-1851 |
| source repo | https://github.com/apache/zookeeper.git |
| fix commit | `bcf09c846cc68c85479659cb1b7c1a076af068cb` |
| pre-fix commit | `25ea38a87b73edfe934886a51b694fe9493a2be2` |
| agent | `agent-run-e47cfc21` |

Runbook: `context/METHODOLOGY.md`. This file and `state.json` are kept in sync; every
milestone carries `status` + `success` + `outcome`.

## Milestones

| ID | Milestone | Status | success | outcome |
|---|---|---|---|---|
| M0 | Scaffold & claim the bug folder | DONE | true | success |
| M1 | From JIRA: fix commit + pre-fix commit | DONE | true | success |
| M2 | Check out pre-fix, build from source, fix deps | DONE | true | success |
| M3 | Reproduce the failure | DONE | true | success |
| M4 | Anonymize, rebuild, re-confirm reproduction | DONE | true | success |
| M5 | Prepare diagnosis inputs & ground truth | DONE | true | success |
| M6 | Run LLM diagnosis x5 (network locked) | PENDING | null | pending |
| M7 | Grade each run vs ground truth | PENDING | null | pending |
| M8 | Write summary & finalize | PENDING | null | pending |

## Log

- 2026-08-12T01:24:23Z M0 IN_PROGRESS — created `evaluations/Zookeeper/Zookeeper-1851/` with `private/ source/ logs/ diagnosis/`, wrote `PROGRESS.md` + `state.json`, claimed the bug in `evaluations/COORDINATION.log`.
- 2026-08-12T01:25:24Z M0 DONE success=true — scaffold complete.
- 2026-08-12T01:28Z M1 DONE success=true — ZOOKEEPER-1851 "Follower and Observer Request Processors Do Not Forward create2 Requests" (Blocker, 3.5.0). Fix commit `bcf09c846` (2014-07-18, svn trunk@1611732) adds `case OpCode.create2:` to `FollowerRequestProcessor.run`, `ObserverRequestProcessor.run`, `CommitProcessor.needCommit`, and `TraceFormatter.op2String`. Pre-fix = `25ea38a87`. Saved `private/fix.diff`.
- 2026-08-12T01:31Z M2 DONE success=true — `ant jar` on the pre-fix tree inside `clods-eval:Zookeeper-Zookeeper-1851` (JDK 8 + Ant). Dep fixes saved to `private/deps-fix.patch`: dead Maven repos (`repo2.maven.org`, `repository.jboss.org`, `download.java.net`) → `https://repo1.maven.org`, and `javac.source`/`javac.target` 1.5 → 1.8. Artifact: `build/zookeeper-3.5.0-SNAPSHOT.jar`.
- 2026-08-12T01:36Z M3 DONE success=true — real 3-node ensemble + real client traffic; create-with-stat on a follower never completes (`ConnectionLoss` after 6.8 s), the follower's `CommitProcessor` dies (`NullPointerException` at `ZKDatabase.addCommittedProposal:251` → "Exception thrown by downstream processor, unable to continue." → "CommitProcessor exited loop!"), the node is never created, and the collateral client on that member fails too. `private/symptom.orig.log` = 19 037 lines (15 615 DEBUG). Write-up in `reproduce.md`.
- 2026-08-12T01:45Z M4 DONE success=true — renamed the one bug-naming term (`create2`→`createExt`, `Create2*`→`CreateExt*`) across `src/java` + `src/zookeeper.jute`, rebuilt the renamed tree at the neutral path `repos/zookeeper-quorum-src` (`ant jar` OK) and re-ran `reproduce.sh` against it: the failure reproduces identically, so `logs/symptom.log` (19 014 lines) is genuine output of the renamed binaries. `source/` = the full renamed pre-fix Java tree (297 files). Ports moved off 2185x so no bare `1851` can appear. Leak check: 0 hits for the ticket id and for `create2` in any case. Regenerate with `private/anonymize.sh`.
- 2026-08-12T01:48Z M5 DONE success=true — wrote `symptom.md` (symptom only) and `private/ground_truth.md`. Answer key: the two primary sites are the missing `case OpCode.createExt:` in `FollowerRequestProcessor.run()`'s forward-to-leader switch (source line 84; the write never reaches the leader) and in `CommitProcessor.needCommit()` (line 133; `default: return false` makes the write get dispatched as a read with a null header). `ObserverRequestProcessor` + `TraceFormatter` are credit-neutral. Leak check across `source/`, `logs/symptom.log`, `symptom.md`: 0 hits.
