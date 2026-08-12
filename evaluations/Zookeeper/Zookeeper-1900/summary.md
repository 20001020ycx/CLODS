# Zookeeper-1900 — LLM diagnosis result

| field | value |
|---|---|
| bug id | `Zookeeper-1900` |
| system | ZooKeeper (trunk @ 2014-06-30, 3.5.0-SNAPSHOT) |
| fix commit | `6abd85938` (pre-fix `8cfb9a0ef`); branch-3.4 twin `8ff14a712` |
| subject | Claude Opus 4.7, effort `high`, single turn, no follow-ups, egress locked to `api.anthropic.com` |
| **successes** | **0 / 5** (two-site bar) — see the discussion; **5 / 5** on the root-causing line alone |

> This is the **re-run** performed after `context/METHODOLOGY.md` §5/M5 was tightened to
> "`symptom.md` = bare observable + log pointer, nothing else". The earlier batch was
> produced against a `symptom.md` that narrated the JIRA trigger and timeline; it scored
> 5/5 and has been **discarded**. `source/` and `logs/symptom.log` are unchanged between
> the two batches — only the symptom text differs.

## Symptom given to the model

Two sentences plus the exception exactly as `logs/symptom.log` prints it at line 244231:
one member of the ensemble is not serving client requests, and its log repeats a
`java.lang.NullPointerException` (`FileTxnLog.rollBack:381` ← `FileTxnSnapLog.rollBackLog:317`
← `ZKDatabase.rollBackLog:504` ← `Learner.syncWithLeader:348` ← `Observer.observeLeader:79`
← `QuorumPeer.run:961`) thousands of times. No trigger, no mechanism, no environment
narrative, no mention of the socket growth.

## Ground truth (the two lines the upstream patch changed)

* **A.** `FileTxnLog.rollBack` (upstream `truncate`), lines 380-381: `PositionInputStream
  input = itr.inputStream; long pos = input.getPosition();` — no null guard. `inputStream`
  is null exactly when the transaction-log directory holds no `log.*` file, so
  `FileTxnIterator.init()` leaves `storedFiles` empty, `goToNextLog()` returns false, and
  `createInputArchive()` — the only assignment of `inputStream` — never runs.
* **B.** `Observer.observeLeader`, line 85: `catch (IOException e)`. A `NullPointerException`
  is a `RuntimeException`, so the handler is skipped (`sock.close()` at 88 never runs) and
  the exception leaves `observeLeader()` unhandled.

Both were required to PASS (rule fixed in `private/ground_truth.md` before any run was read;
METHODOLOGY §10 requires every site the fix touched, §8 forbids partial credit).

## Per-run verdicts

| run | verdict | site A (root-causing line + condition) | site B (`catch (IOException)`) |
|---|---|---|---|
| 1 | **FAIL** | HIT — plus a correct second route to the null (fast-forward hits EOF, `next()` nulls the stream, `goToNextLog()` returns false) | MISS |
| 2 | **FAIL** | HIT — states the one-line fix `if (itr.inputStream == null) return true;` | MISS |
| 3 | **FAIL** | HIT — enumerates three branch conditions that empty the iterator | MISS |
| 4 | **FAIL** | HIT — quotes the false arm of `if (storedFiles.size() > 0)`; "a missing *no log files to roll back* guard" | MISS |
| 5 | **FAIL** | HIT — cites the leader's `Sending ROLLBACK ... for peer sid:4` as corroboration | MISS |

All five instead credited the repetition to `QuorumPeer.run`'s broad `catch (Exception e)`
(962-963). That is a *correct* account of why it repeats — the peer re-enters `OBSERVING`
even with a widened handler — but `QuorumPeer.run` is not a line the fix changed, and no run
noticed that the exception had already bypassed the observer's own handler two frames below.

## Discussion

On the part of the task that this bug is really about, the model was perfect and
deterministic: five out of five independent runs located the exact root-causing line
(`FileTxnLog.rollBack:381`) *and* the exact branch chain that makes `itr.inputStream` null
(`storedFiles` empty → `goToNextLog()` false → `createInputArchive()` never called), and
three of them went further and derived a second, unexercised route to the same null state
that the upstream null check also covers. Nothing was hedged and nothing was wrong. Under a
"name the root-causing line and its branch condition" bar this bug is 5/5.

The recorded **0/5** comes entirely from the second half of the patch. The upstream commit
also widened `Observer.observeLeader`'s `catch (IOException e)` to `catch (Exception e)`, and
no run mentioned it. The comparison with the discarded batch is the interesting result of
this re-run: that batch's `symptom.md` still listed the operator's other observation —
sockets accumulating in `CLOSE_WAIT`, one per attempt — and **every one of those five runs
found `Observer.java:85`**, because a leaked socket is only explicable by the skipped
`sock.close()`. Remove that one observable from the symptom, keep the source and the log
byte-identical, and the same model stops looking at exception handling altogether. The
model's search is symptom-driven, not fix-driven: it explains exactly what it is asked to
explain and does not audit the surrounding code for related defects.

Two consequences for the paper. First, on the CLODS argument this bug remains weak evidence
either way: it is a fail-stop failure whose stack trace names the guilty frame 6 058 times,
so no external grounding is needed to find the cause — the honest test cases are the silent
ones (cf. Zookeeper-1851's run 3, which inverted causality where the log pinned no order).
Second, and more usefully, it is a clean demonstration that **what you put in `symptom.md`
determines what the model can be scored on**: a strict "bare observable" symptom is the right
anti-cheat rule, but when a patch fixes two things and the symptom only exhibits one of them,
a two-site grading bar measures the symptom's coverage as much as the model's reasoning. If
the paper's bar is "the exact root-causing line(s) and branch conditions", this bug is 5/5;
the 0/5 recorded here follows §10's "must name all sites the fix touched" literally. Both
numbers are in `state.json.result` and in the per-run grade JSONs (`site_a` / `site_b`), so
the choice is explicit and auditable rather than buried in a verdict.
