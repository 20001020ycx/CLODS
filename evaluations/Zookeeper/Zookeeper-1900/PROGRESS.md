# Zookeeper-1900 — milestone tracker

| field | value |
|---|---|
| bug id | `Zookeeper-1900` |
| system | Zookeeper |
| JIRA | https://issues.apache.org/jira/browse/ZOOKEEPER-1900 |
| source repo | https://github.com/apache/zookeeper.git |
| fix commit | `6abd85938f450587ec1c8973176261fb60a6838b` (trunk/3.5.0; branch-3.4 companion `8ff14a712`) |
| pre-fix commit | `8cfb9a0efa5c8934eb3c95ca69566c718a37d9ca` |
| agent | `agent-run-ea3110e6` |

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

- 2026-08-12T17:42:49Z M0 IN_PROGRESS — created `evaluations/Zookeeper/Zookeeper-1900/` with `private/ source/ logs/ diagnosis/`, wrote `PROGRESS.md` + `state.json`, claimed the bug in `evaluations/COORDINATION.log`.
- 2026-08-12T17:44:30Z M0 DONE success=true — scaffold complete.
- 2026-08-12T17:58Z M1 DONE success=true — ZOOKEEPER-1900 "NullPointerException in truncate" (Blocker; affects 3.4.5/3.4.6, fixed in 3.4.7 + 3.5.0).
  Fix commit `6abd85938` (trunk, 2014-06-30) changes two production lines: a `if (input == null) throw new IOException(...)` guard in `FileTxnLog.truncate()`, and `catch (IOException e)` → `catch (Exception e)` in `Observer.observeLeader()`; it also adds `TruncateTest.testTruncationNullLog`. Pre-fix = `8cfb9a0ef`. Saved `private/fix.diff` (+ `private/fix.branch-3.4.diff`, which additionally widens the same catch in `Follower.java` — trunk's `Follower` already caught `Exception`, so on trunk only an **observer** exercises that second site).
- 2026-08-12T18:05Z M2 DONE success=true — `ant jar` on the pre-fix tree inside `clods-eval:Zookeeper-Zookeeper-1900` (JDK 8 + Ant). Dep fixes saved to `private/deps-fix.patch`: dead Maven repos (`repo2.maven.org`, `repository.jboss.org`, `download.java.net`) → `https://repo1.maven.org`, and `javac.source`/`javac.target` 1.5 → 1.8. Artifact: `build/zookeeper-3.5.0-SNAPSHOT.jar`.
- 2026-08-12T18:35Z M3 DONE success=true — real 4-node ensemble (3 participants + 1 observer) + real client traffic. After the three participants are re-provisioned and the observer's `dataLogDir` is repointed at an empty directory, the observer never rejoins: **6 239** `NullPointerException`s in 40 s (`FileTxnLog.truncate:381` ← `FileTxnSnapLog.truncateLog:317` ← `ZKDatabase.truncateLog:504` ← `Learner.syncWithLeader:348` ← `Observer.observeLeader:79` ← `QuorumPeer.run:961`), `LOOKING`→`OBSERVING` forever, `srvr` answers "not currently serving requests", an ordinary client times out connecting to it, and its open sockets grow 25→122 (CLOSE_WAIT 0→42) while the quorum serves 185 ops with 0 failures. `private/symptom.orig.log` = 524 674 lines / 75 MB. Write-up in `reproduce.md`.
- 2026-08-12T19:12Z M4 DONE success=true — renamed the one bug-naming vocabulary (`truncate*`/`TRUNC` → `rollBack*`/`ROLLBACK`) across `src/java`, rewrote the two log messages the ticket quotes, rebuilt the renamed tree at the neutral path `repos/zookeeper-ensemble-src` (`ant jar` OK) and re-ran `reproduce.sh` against it: the failure reproduces identically (6 058 NPEs in 40 s at `FileTxnLog.rollBack:381`), so `logs/symptom.log` (512 839 lines) is genuine output of the renamed binaries. `source/` = the full renamed pre-fix Java tree (282 files). Leak check: 0 hits for `ZOOKEEPER-1900`, `\b1900\b`, `[Tt]runcat`, `\bTRUNC\b`. Regenerate with `private/anonymize.sh`.
- 2026-08-12T19:20Z M5 DONE success=true — wrote `symptom.md` (symptom only; the exception type and stack frames are deliberately left for the LLM to find in the log) and `private/ground_truth.md`. Answer key: **(A)** the unguarded `itr.inputStream` dereference in `FileTxnLog.rollBack` (source lines 380-381) plus the exact condition that makes it null (no `log.*` file in the txn-log dir → `FileTxnIterator.init()` leaves `storedFiles` empty → `goToNextLog()` false → `createInputArchive()` never runs), and **(B)** `Observer.observeLeader`'s `catch (IOException e)` (line 85) not catching the `RuntimeException`, so `sock.close()` is skipped (leaked socket / CLOSE_WAIT) and the failure escalates to `QuorumPeer.run` → endless `LOOKING`→`OBSERVING`. `LearnerHandler`/`Learner`/`ZKDatabase.clear()` context is credit-neutral. Leak check across `source/`, `logs/symptom.log`, `symptom.md`: 0 hits.

## Diagnosis harness (M6) — deviation from the documented command

`context/METHODOLOGY.md` §11 says to run `--entrypoint /opt/clods/run_diagnosis.sh`. **That
baked-in copy is still stale** in the `clods-eval` image (`md5 246ce82e…` vs `324f602b…`
for the tracked `context/run_diagnosis.sh`), exactly as recorded for Zookeeper-1851: it
points the prompt at `/bug/source` + `/bug/logs/symptom.log` (so `/bug/private/` would be
reachable by the diagnosed agent), denies only `WebFetch,WebSearch`, and pins neither
`--model` nor `--effort`. This bug's M6 therefore mounts the tracked script read-only and
executes that instead — no file in `context/` was modified and the image was not rebuilt:

```bash
docker run --rm --name clods-diag-zk1900 --cap-add=NET_ADMIN --add-host api.anthropic.com:<ip> \
  -v "$PWD/context:/clods-context:ro" \
  -v "$PWD/evaluations/Zookeeper/Zookeeper-1900:/bug" \
  -v "<scratch-config-with-oauth-creds>:/root/.claude" \
  -e CLAUDE_CONFIG_DIR=/root/.claude -e IS_SANDBOX=1 -e CLAUDE_PURITY_FLAG=--safe-mode \
  --entrypoint bash clods-eval -lc 'bash /clods-context/run_diagnosis.sh /bug'
```

Verified while the batch was running: the staging dir held only `source/ logs/ symptom.md`
(no `private/`), the prompt paths were `/tmp/clods-diag-XXXX/{source,logs/symptom.log}`, the
flags were `--model claude-opus-4-7 --effort high --safe-mode --no-session-persistence
--exclude-dynamic-system-prompt-sections --disallowed-tools Bash,Write,Edit,WebFetch,
WebSearch,Task,NotebookEdit --permission-mode bypassPermissions`, and `iptables -S` showed
`-P OUTPUT DROP` with a single `ACCEPT` to the API on 443. `--safe-mode` replaces `--bare`
(documented in the script) because `--bare` refuses the mounted CCS OAuth credentials;
`IS_SANDBOX=1` is needed because the script passes `--permission-mode bypassPermissions` and
iptables requires root. The scratch credential copy was deleted after the run.

**Operator action suggested (repeat of the Zookeeper-1851 note):** rebuild `clods-eval` so
`/opt/clods/run_diagnosis.sh` matches `context/run_diagnosis.sh`.
- 2026-08-12T19:44Z M6 DONE success=true — 5 single-turn diagnoses (`claude-opus-4-7`, effort high, network locked, staged inputs only, no follow-ups). All 5 completed first time; all stderr empty. See the harness-deviation section above.
- 2026-08-12T19:50Z M7 DONE success=true — **5/5 PASS**. Each run named the unguarded `itr.inputStream` dereference at `FileTxnLog.rollBack` (380-381) *with* the condition that makes it null (no `log.*` in the replacement txnlog volume → `storedFiles` empty → `goToNextLog()` false → `createInputArchive()` never runs) **and** `Observer.observeLeader`'s `catch (IOException e)` at line 85 not catching the `RuntimeException`, hence the skipped `sock.close()`, the CLOSE_WAIT growth and the endless `LOOKING`→`OBSERVING` retry via `QuorumPeer.run`. (The grade JSONs were written just before the M6 commit and got swept into it; history was not rewritten.)
- 2026-08-12T19:55Z M8 DONE success=true — `summary.md` written; `state.json.result` = 5/5 PASS (`["PASS","PASS","PASS","PASS","PASS"]`). Bug complete.

- 2026-08-12T20:12Z **M5 REDONE** success=true — `context/METHODOLOGY.md` §5/M5 was tightened to "`symptom.md` = bare observable + log pointer, nothing else". The first `symptom.md` violated it (it narrated the trigger and timeline — maintenance window, participants re-provisioned, the member's transaction-log directory repointed — plus the mechanism and the "quorum is healthy / sockets pile up in CLOSE_WAIT" narrowing comparisons). Rewritten as two sentences + the exception exactly as `logs/symptom.log` prints it at line 244231. `private/ground_truth.md` keeps the same two required sites; only B's justification is restated (the CLOSE_WAIT consequence is no longer required, since it left the symptom). Verification gate re-run: 0 hits for the bug id, bare `1900`, `[Tt]runcat`, `TRUNC`; sentence-by-sentence audit clean.
- 2026-08-12T20:12Z **M6–M8 reset to PENDING** — the earlier batch (5/5 PASS) was produced against the cause-leaking `symptom.md` and is **discarded, not part of the record**. `source/` and `logs/symptom.log` are unchanged, so M2–M4 stand and only the diagnosis is re-run.
