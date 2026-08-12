# Zookeeper-1900 — LLM diagnosis result

| field | value |
|---|---|
| bug id | `Zookeeper-1900` |
| system | ZooKeeper (trunk @ 2014-06-30, 3.5.0-SNAPSHOT) |
| fix commit | `6abd85938` (pre-fix `8cfb9a0ef`); branch-3.4 twin `8ff14a712` |
| subject | Claude Opus 4.7, effort `high`, single turn, no follow-ups, egress locked to `api.anthropic.com` |
| **successes** | **5 / 5** |

## Symptom

A four-member ensemble (three participants + one observer) is rebuilt: the participants are
re-provisioned on empty storage, and the observer keeps its snapshot directory while its
transaction-log directory is repointed at a replacement volume. The quorum comes back
healthy and serves clients, but the observer never rejoins — every attempt to join the
leader ends in an unhandled exception, it drops to leader election and retries many times a
second forever (6 058 failed attempts in the 40-second observation window), it never serves
a client, and it leaks one connection to the leader per attempt (open sockets 35 → 113,
CLOSE_WAIT 0 → 32).

## Ground truth (the two lines the upstream patch changed)

* **A.** `FileTxnLog.rollBack` (upstream `truncate`), lines 380-381: `PositionInputStream
  input = itr.inputStream; long pos = input.getPosition();` — no null guard. `inputStream`
  is null exactly when the configured transaction-log directory holds no `log.*` file, so
  `FileTxnIterator.init()` leaves `storedFiles` empty, `goToNextLog()` returns false, and
  `createInputArchive()` — the only assignment of `inputStream` — never runs.
* **B.** `Observer.observeLeader`, line 85: `catch (IOException e)`. The `NullPointerException`
  is a `RuntimeException`, so the handler is skipped, `sock.close()` never runs (leaked
  socket → CLOSE_WAIT) and the exception escalates to `QuorumPeer.run` → `LOOKING` →
  re-observe → the same failure, indefinitely.

A run had to name **both** sites with their branch conditions to pass (rule fixed in
`private/ground_truth.md` before any run was read; no partial credit).

## Per-run verdicts

| run | verdict | what it named |
|---|---|---|
| 1 | **PASS** | A (380-381 + init/goToNextLog/createInputArchive chain) and B (85, skipped `sock.close()`, escape to `QuorumPeer.run:962` → `LOOKING`) |
| 2 | **PASS** | Same, and states the defect outright: "No null check on `itr.inputStream`; the code assumes the iterator always opened a file" |
| 3 | **PASS** | Same; calls A the "proximate defect" and B the "amplifier" — exactly the split of the upstream patch |
| 4 | **PASS** | Same, ending in a 7-row table of decisive conditions; also explains why no iteration can make progress |
| 5 | **PASS** | Same, with a summary table; frames the remedy operationally rather than as the code fix (not required by the rule) |

## Discussion

The model isolated this failure **deterministically**: all five independent runs converged on
the same two lines and the same two branch conditions, with no wrong or hedged answers, and
each additionally reconstructed the credit-neutral context (why the leader ordered a
roll-back at all, and why `Learner.shutdown` leaves the leader socket open). That is a much
cleaner result than the neighbouring Zookeeper-1851 (4/5), and the reason is visible in the
inputs: here the crash is *self-reporting*. The observer's own DEBUG log carries a stack
trace naming `FileTxnLog.rollBack(FileTxnLog.java:381)` 6 058 times, so the root-causing
line is handed to the reader by the runtime; the only real reasoning left is static — why
`itr.inputStream` can be null on that path, and why an exception handler two frames up
converts a one-shot error into an unbounded retry-and-leak loop. Both are short, local
deductions inside a single class and a single method, and the model made them reliably.

The honest reading is therefore narrow. This bug is a *fail-stop* defect whose symptom
points at its own cause, which is the regime where an LLM reading logs plus source needs no
external grounding — and the runs confirm that. It says little about the cases CLODS targets:
failures that are silent at the point of corruption, where the visible symptom is separated
from the root cause by successful-looking intermediate state and no stack trace marks the
guilty frame (Zookeeper-1851's run 3 failed exactly there, inverting the causality between
two switch statements because nothing in the log pinned the order). Two further caveats
belong on the record: the anonymization renamed the truncation vocabulary
(`truncate*`/`TRUNC` → `rollBack*`/`ROLLBACK`), yet runs 1, 3 and 5 still call the packet
"TRUNC" in prose — general ZooKeeper familiarity survives the rename, even though the
specific ticket could not be string-matched; and the two required sites happen to be the two
frames the trace and the retry pattern already highlight, so this bug measures precise
reading more than it measures search.
