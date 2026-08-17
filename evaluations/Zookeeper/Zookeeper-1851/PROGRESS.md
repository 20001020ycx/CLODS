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
| M3 | Reproduce the failure + merge into production log | DONE | true | success |
| M4 | Anonymize failure path (file/type + log literals), rebuild, re-reproduce, re-merge | DONE | true | success |
| M5 | Prepare diagnosis inputs & ground truth | DONE | true | success |
| M6 | Run LLM diagnosis x5 (network locked) | DONE | true | success |
| M7 | Grade each run vs ground truth | DONE | true | success |
| M8 | Write summary & finalize | DONE | true | success |

## Log

- 2026-08-12T01:24:23Z M0 IN_PROGRESS — created `evaluations/Zookeeper/Zookeeper-1851/` with `private/ source/ logs/ diagnosis/`, wrote `PROGRESS.md` + `state.json`, claimed the bug in `evaluations/COORDINATION.log`.
- 2026-08-12T01:25:24Z M0 DONE success=true — scaffold complete.
- 2026-08-12T01:28Z M1 DONE success=true — ZOOKEEPER-1851 "Follower and Observer Request Processors Do Not Forward create2 Requests" (Blocker, 3.5.0). Fix commit `bcf09c846` (2014-07-18, svn trunk@1611732) adds `case OpCode.create2:` to `FollowerRequestProcessor.run`, `ObserverRequestProcessor.run`, `CommitProcessor.needCommit`, and `TraceFormatter.op2String`. Pre-fix = `25ea38a87`. Saved `private/fix.diff`.
- 2026-08-12T01:31Z M2 DONE success=true — `ant jar` on the pre-fix tree inside `clods-eval:Zookeeper-Zookeeper-1851` (JDK 8 + Ant). Dep fixes saved to `private/deps-fix.patch`: dead Maven repos (`repo2.maven.org`, `repository.jboss.org`, `download.java.net`) → `https://repo1.maven.org`, and `javac.source`/`javac.target` 1.5 → 1.8. Artifact: `build/zookeeper-3.5.0-SNAPSHOT.jar`.
- 2026-08-12T01:36Z M3 DONE success=true — real 3-node ensemble + real client traffic; create-with-stat on a follower never completes (`ConnectionLoss` after 6.8 s), the follower's `CommitProcessor` dies (`NullPointerException` at `ZKDatabase.addCommittedProposal:251` → "Exception thrown by downstream processor, unable to continue." → "CommitProcessor exited loop!"), the node is never created, and the collateral client on that member fails too. `private/symptom.orig.log` = 19 037 lines (15 615 DEBUG). Write-up in `reproduce.md`.
- 2026-08-12T01:45Z M4 DONE success=true — renamed the one bug-naming term (`create2`→`createExt`, `Create2*`→`CreateExt*`) across `src/java` + `src/zookeeper.jute`, rebuilt the renamed tree at the neutral path `repos/zookeeper-quorum-src` (`ant jar` OK) and re-ran `reproduce.sh` against it: the failure reproduces identically, so `logs/symptom.log` (19 014 lines) is genuine output of the renamed binaries. `source/` = the full renamed pre-fix Java tree (297 files). Ports moved off 2185x so no bare `1851` can appear. Leak check: 0 hits for the ticket id and for `create2` in any case. Regenerate with `private/anonymize.sh`.
- 2026-08-12T01:48Z M5 DONE success=true — wrote `symptom.md` (symptom only) and `private/ground_truth.md`. Answer key: the two primary sites are the missing `case OpCode.createExt:` in `FollowerRequestProcessor.run()`'s forward-to-leader switch (source line 84; the write never reaches the leader) and in `CommitProcessor.needCommit()` (line 133; `default: return false` makes the write get dispatched as a read with a null header). `ObserverRequestProcessor` + `TraceFormatter` are credit-neutral. Leak check across `source/`, `logs/symptom.log`, `symptom.md`: 0 hits.

## Diagnosis harness (M6) — deviation from the documented command

`context/METHODOLOGY.md` §11 says to run `--entrypoint /opt/clods/run_diagnosis.sh`. **That
baked-in copy is stale**: the `clods-eval` image was built 2026-08-10T14:35 and
`context/run_diagnosis.sh` was last updated at 15:43 the same day. The image's copy
(a) points the prompt at `/bug/source` and `/bug/logs/symptom.log` instead of a throwaway
staging dir — so `/bug/private/` (`ground_truth.md`, `fix.diff`) would be reachable by the
diagnosed agent, (b) denies only `WebFetch,WebSearch` (leaving `Bash`/`Task`/`Write`
enabled), and (c) pins neither `--model` nor `--effort`, so the subject would not be
Opus 4.7. A first M6 attempt used it and was **discarded** (3 runs deleted unread-for-grading).

The rerun mounts the tracked script read-only and executes that instead — no file in
`context/` was modified and the image was not rebuilt:

```bash
docker run -d --name clods-diag-1851 --cap-add=NET_ADMIN --add-host api.anthropic.com:<ip> \
  -v "$PWD/context:/clods-context:ro" \
  -v "$PWD/evaluations/Zookeeper/Zookeeper-1851:/bug" \
  -v "<scratch-config-with-oauth-creds>:/root/.claude" \
  -e CLAUDE_CONFIG_DIR=/root/.claude -e IS_SANDBOX=1 -e CLAUDE_PURITY_FLAG=--safe-mode \
  --entrypoint bash clods-eval -lc 'bash /clods-context/run_diagnosis.sh /bug'
```

Verified while running: prompt paths are `/tmp/clods-diag-XXXX/{source,logs/symptom.log}`,
the staging dir contains only `source/ logs/ symptom.md` (no `private/`), flags are
`--model claude-opus-4-7 --effort high --safe-mode --no-session-persistence
--exclude-dynamic-system-prompt-sections --disallowed-tools Bash,Write,Edit,WebFetch,
WebSearch,Task,NotebookEdit`, and egress is iptables-locked to api.anthropic.com:443.
`--safe-mode` replaces `--bare` (documented in the script) because `--bare` refuses the
mounted OAuth credentials; `IS_SANDBOX=1` is needed because the script passes
`--permission-mode bypassPermissions` and iptables requires root.

**Operator action suggested:** rebuild `clods-eval` so `/opt/clods/run_diagnosis.sh` matches
`context/run_diagnosis.sh`, and re-check any bug whose M6 used the baked-in entrypoint.
- 2026-08-12T02:20Z M6 DONE success=true — 5 single-turn diagnoses (`claude-opus-4-7`, effort high, network locked, staged inputs only). Run 5 was re-run once after the host rotated the OAuth token mid-batch (`401 ... revoked`); its failed placeholder was deleted first so the script would not skip it. See the harness-deviation section above.
- 2026-08-12T02:22Z M7 DONE success=true — **4/5 PASS** (runs 1, 2, 4, 5). Run 3 FAIL: it names only `CommitProcessor.needCommit()`, never mentions `FollowerRequestProcessor` (0 occurrences), and misattributes the missing forward-to-leader step to the `needCommit` defect; its prescribed one-line fix would leave the follower dark (stalling in `nextPending`) rather than repair it.
- 2026-08-12T02:24Z M8 DONE success=true — `summary.md` written; `state.json.result` = 4/5 PASS (`["PASS","PASS","FAIL","PASS","PASS"]`). Bug complete.

## M5 redone under the updated specification (2026-08-12)

`context/METHODOLOGY.md` M5 was tightened (commits `466a79e`, `ebba23d`, `8d90c20`):
`symptom.md` must now be **the bare observable + a pointer to the log, nothing else** — no
trigger, no mechanism/timeline, no at-fault component, no failing overload/path, and no
"what stays correct" narrowing comparison.

The first `symptom.md` breached all of those: it named the `create(path, data, acl,
createMode, Stat)` overload, described the ensemble topology and the post-failure timeline,
and added "a plain create on the very same connection had succeeded 8 ms earlier" — which
hands the model the discriminating experiment. Under the new rule that is a cheat.

The replacement uses the exception form: two sentences of observable (client calls fail with
`KeeperException.ConnectionLoss`), the log pointer, and the client-side line pasted verbatim
from `logs/symptom.log`. Verification gate re-run: 0 hits for the ticket id or the original
distinctive term across `source/`, `logs/symptom.log`, `symptom.md`; sentence-by-sentence
audit finds no cause statement. `private/ground_truth.md` is unchanged.

All post-M5 results (`diagnosis/*`, `summary.md`) were deleted and M6–M8 reset to PENDING;
the experiment is re-run from M6 against the new `symptom.md`.

- 2026-08-12T20:30Z M5 REDONE success=true — new `symptom.md`; M6–M8 reset.
- 2026-08-12T20:33Z M6 DONE success=true (re-run) — 5 fresh single-turn diagnoses against the new `symptom.md`; all 5 completed first try, every stderr empty.
- 2026-08-12T20:35Z M7 DONE success=true (re-run) — **4/5 PASS** (runs 1, 3, 4, 5). Run 2 FAIL: names only `CommitProcessor.needCommit()`, never identifies the forwarding switch, and explains the null header as a timing race with a COMMIT that was in fact never requested.
- 2026-08-12T20:37Z M8 DONE success=true (re-run) — `summary.md` rewritten; `state.json.result` = 4/5 PASS (`["PASS","FAIL","PASS","PASS","PASS"]`) under M5 v2, with the superseded M5 v1 result retained under `result.superseded_result`. Bug complete.

## M3/M4 redone under the updated methodology (2026-08-16)

`context/METHODOLOGY.md` now requires (a) two M3 logs — the standalone reproduction **and**
that reproduction merged into the shared GB-scale `production-logs/<SYSTEM>/production.log`,
which is what the LLM is given; and (b) an M4 that renames **failure-path file/type names**
and rewrites **failure-path log statements**, with both logs regenerated from the anonymized
source.

- 2026-08-16T04:05Z M3 REDONE success=true — neutral repro naming (`/app/svcN/item-9137`, `c1..c4`, production-style collection headers) because the old `/app/failing/with-stat` named the failing session and the at-fault operation. Log A `private/symptom.orig.log` (19 049 lines); Log B `private/merged.orig.log` (8 068 887 lines, 1.5 GB) via `private/merge_logs.py`. Merge deviation (per-host-bundle production log ⇒ position interleaving) documented in `reproduce.md`.
- 2026-08-16T04:25Z M4 REDONE success=true — failure-path **file/type renames** (`FollowerRequestProcessor`→`FollowerIngressProcessor`, `CommitProcessor`→`StagedRequestProcessor`, `FinalRequestProcessor`→`TerminalRequestProcessor`, `ZKDatabase`→`ZKStateStore`, `WorkerService`→`TaskExecutorPool`, `ObserverRequestProcessor`→`ObserverIngressProcessor`, `TraceFormatter`→`OpNameFormatter`) and **log-statement rewrites** (`Processing request:: `→`Handling submission:: `, `… unable to continue.`→`Downstream stage failed; cannot continue.`, `Client session timed out, have not heard from server in `→`Session inactive - no server traffic for `, …). Tree rebuilt and re-reproduced; `logs/repro.log` (18 991 lines) and the merged `logs/symptom.log` (8 072 681 lines, 1.5 GB) regenerated from it. The same map is applied to the production stream of the merged log — the real production noise mentions `CommitProcessor` 5.5 M times. All leakage checks zero.
- 2026-08-16T04:30Z M5 REDONE success=true — `symptom.md` re-pasted from the anonymized log and switched to the **merged-log pointer form** (no line number, no marker: the LLM greps 8.07 M lines for the observable). `private/ground_truth.md` gains the §8 real↔anonymized cross-reference table. Prepared `private/run_diagnosis.prodlog.sh` (one-line prompt difference from the tracked script — see below).

### Harness note 2 — the M6 prompt

METHODOLOGY §5/M6 now specifies a production-log prompt ("*the production log at … — grep it
for the symptom rather than reading it whole*"), but the tracked `context/run_diagnosis.sh`
still carries the older "*symptom logs located at …*" wording. `context/` is read-only for an
agent, so this bug runs `private/run_diagnosis.prodlog.sh` — a copy whose **only** difference
(verified by `diff`: exactly one line) is that prompt. Operator: please fold the new prompt
into `context/run_diagnosis.sh`.
- 2026-08-16T05:50Z M6 DONE success=true — 5 diagnoses against the 1.5 GB merged production log (13–27 min each). Two auth-only false starts discarded; accepted batch clean.
- 2026-08-16T05:52Z M7 DONE success=true — **0/5 PASS**. Runs 2/4/5 found the real chain but named only `needCommit()`; runs 1/3 never found the NPE and invented a stall mechanism.
- 2026-08-16T05:54Z M8 DONE success=true — `summary.md`; `state.json.result` = 0/5, with both standalone-log results kept under `result.superseded_results`.
- 2026-08-17T19:15Z **Extra M6 batch (gateway endpoint)** — `context/run_diagnosis.sh` was switched to the yscope-anthropic-paper-validation gateway (bearer token, egress locked to `llm-gateway.yscope.io`). Re-ran the 5 diagnoses on the merged production log into `diagnosis/2026-08-17/`; the 2026-08-16 batch is untouched. **0/4 PASS**, run 5 blocked by the gateway's daily `claude-opus-4-7` quota (resets 2026-08-18 08:00 EDT). None of the four found the NPE or `createExt`; all four diagnosed a head-of-line-blocking stall. An earlier OAuth attempt from the same day is preserved in `diagnosis/2026-08-17-oauth-superseded/` (4 runs; run 5 hit the subscription session limit). Details + the context-window confound in `diagnosis/2026-08-17/README.md`.
