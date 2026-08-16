# Zookeeper-1900 — LLM diagnosis result

| field | value |
|---|---|
| bug id | `Zookeeper-1900` |
| system | ZooKeeper (trunk @ 2014-06-30, 3.5.0-SNAPSHOT) |
| fix commit | `6abd85938` (pre-fix `8cfb9a0ef`); branch-3.4 twin `8ff14a712` |
| subject | Claude Opus 4.7, effort `high`, single turn, no follow-ups, egress locked to `api.anthropic.com` |
| LLM-facing log | `logs/symptom.log` — **8 560 248 lines / 1.6 GB**: the shared production log (8 052 741 records) with this bug's 380 769 reproduction records retimed and spread through it |
| **successes** | **0 / 5** (two-site bar) — 3/5 fully correct on the root-causing line *and* its exact condition; 5/5 named the root-causing line |

> Third batch. It supersedes both earlier ones: batch 1 (5/5) used a cause-leaking
> `symptom.md`; batch 2 (0/5) used the bare-observable symptom but the pre-rewrite M4
> artifacts. This batch runs under the current methodology end to end — failure-path
> file/type + log-statement anonymization, and the merged GB-scale production log.

## What the model was given

* `source/` — 282 Java files with every failure-path type renamed (`FileTxnLog`→`TxnJournal`,
  `Observer`→`ObserverPeer`, `QuorumPeer`→`EnsembleMember`, `Learner`→`PeerSynchronizer`,
  `ZKDatabase`→`ZKStateStore`, `FileTxnSnapLog`→`JournalSnapStore`, …) and 17 failure-path log
  literals rewritten.
* `logs/symptom.log` — the merged production log. The reproduction is not a block: its records
  are distributed across all ten per-host sections, one reproduction record per ~21 production
  records.
* `symptom.md` — two sentences plus the pasted stack, with only the "the log for this run is
  `logs/symptom.log`" pointer: no line number, no marker. The model had to find the failure by
  grepping 8.5 M lines.

## Ground truth (the two lines the upstream patch changed)

* **A.** `FileTxnLog.truncate` = `TxnJournal.rollBack`, lines 380-381 — `PositionInputStream
  input = itr.inputStream; long pos = input.getPosition();` with no null guard. `inputStream`
  is null exactly when the transaction-log directory holds no `log.*` file, so `init()` leaves
  `storedFiles` empty, `goToNextLog()` returns false and `createInputArchive()` never runs.
* **B.** `Observer.observeLeader` = `ObserverPeer.observeLeader`, line 85 — `catch (IOException e)`
  does not catch a `RuntimeException`, so the handler is skipped and the exception leaves
  `observeLeader` unhandled.

Both were required to PASS (rule fixed in `private/ground_truth.md` before any run was read).

## Per-run verdicts

| run | verdict | site A: line | site A: exact condition | site B |
|---|---|---|---|---|
| 1 | **FAIL** | HIT | PARTIAL — asserts the fast-forward/EOF route instead | MISS |
| 2 | **FAIL** | HIT | PARTIAL — EOF route "consistent with the log", citing a **production** line as if it were the failing member's; names the correct route only as an aside | MISS |
| 3 | **FAIL** | HIT | HIT — reconstructs the trigger from the merged log and walks the empty-directory chain exactly | MISS |
| 4 | **FAIL** | HIT | HIT — quotes the member's own `datadir:…/txnlog-vol2 snapDir:…/data` line, then the same chain | MISS |
| 5 | **FAIL** | HIT | HIT — enumerates both routes; Branch A stated exactly | MISS |

Verified against the reproduction: the log contains **zero** `Opened journal segment for
reading` and **zero** `EOF excepton` lines, so `createInputArchive()` never ran — the actual
route is the empty-log-directory one. Runs 1 and 2 chose the other one.

## Discussion

Every run found the crash site — the unguarded `itr.inputStream` dereference at
`TxnJournal.java:380-381` — inside a 1.6 GB log it had to grep, under class and message names
it had never seen. Three of five then derived the exact branch chain that makes the stream
null, and two of those (runs 3 and 4) went further than any earlier batch: they recovered the
*trigger* from the merged log itself, spotting that the member had restarted with its
transaction-log directory pointed at a fresh volume while its snapshot directory was retained.
Nothing in `symptom.md` said that; it came out of the noise. So the merge did not impede the
diagnosis — GB-scale production noise cost the model nothing on the part of the task it does
well.

The noise did produce one clean failure mode. Run 2 justified the wrong mechanism by citing
`log.100000001` at line 1 788 380 "for myid=4" — a line belonging to a *production* host that
happens to share the myid, 23 minutes and one host-section away from the incident. That is
exactly the confusion a merged log is meant to create, and it is the first time in three
batches that a run's reasoning was visibly corrupted by evidence rather than merely
incomplete. Run 1 reached the same wrong route without citing evidence at all.

The recorded **0/5** again comes entirely from site B. No run mentioned
`ObserverPeer.observeLeader`'s `catch (IOException e)` — not one of fifteen runs across the two
bare-observable batches has, whereas all five runs of the batch whose symptom mentioned
CLOSE_WAIT sockets found it. The pattern is now well supported: the model explains exactly the
observable it is given and does not audit adjacent code for related defects. Since the current
M5 rule forbids putting the socket growth in `symptom.md`, a two-site bar on this bug measures
symptom coverage as much as reasoning. Both numbers are recorded — `state.json.result` carries
`successes: 0` alongside `site_a_line_successes: 5` and `site_a_full_successes: 3`, and each
grade JSON carries `site_a`/`site_b` — so the operator can apply either bar without a re-run.
For the CLODS argument the standing caveat holds: this is a fail-stop bug whose stack trace
names the guilty frame, so it tests precise reading in a haystack, not the silent-corruption
regime the tool is aimed at.
