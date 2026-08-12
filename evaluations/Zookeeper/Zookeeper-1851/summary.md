# Zookeeper-1851 — LLM diagnosis result

| field | value |
|---|---|
| bug id | `Zookeeper-1851` |
| system | Apache ZooKeeper, trunk @ 2014-07 (3.5.0-SNAPSHOT) |
| fix commit | `bcf09c846` (pre-fix `25ea38a87`) |
| subject | Claude Opus 4.7, effort `high`, single turn, no internet |
| symptom spec | M5 v2 — bare observable + log pointer only |
| **result** | **4 / 5 PASS** |

## Symptom given to the model

The whole of `symptom.md`: client calls fail with `KeeperException.ConnectionLoss`, a
pointer to `logs/symptom.log`, and the one client-side line the log prints —
`Client session timed out, have not heard from server in 6670ms for sessionid 0x…,
closing socket connection and attempting reconnect`. No trigger, no operation, no
component, no comparison. Every run had to find the failing operation itself.

## Ground truth (the two sites on the failure path)

The upstream fix adds one `case OpCode.create2:` label to four opcode switches
(anonymized here as `createExt`). Two are on the reproduced failure path:

1. `FollowerRequestProcessor.run()`'s forward-to-leader `switch (request.type)` (line 84) —
   `createExt` matches no case and there is no `default:`, so
   `zks.getFollower().request(request)` never runs: **the leader never sees the write**.
2. `CommitProcessor.needCommit()` (line 133) — `createExt` falls to `default: return false`,
   so `run()`'s `if (needCommit(request)) … else sendToNextProcessor(request)` guard takes
   the **else** arm and hands the write to `FinalRequestProcessor` as if it were a read,
   with `request.getHdr() == null`.

Downstream (not required in an answer): `Request.isQuorum()` *does* list `createExt`, so
`FinalRequestProcessor` calls `ZKDatabase.addCommittedProposal()`, whose
`request.getHdr().serialize(...)` throws NPE; `WorkerService` runs
`CommitWorkRequest.cleanup()`, which halts the `CommitProcessor` for good.
`ObserverRequestProcessor` (no observer in the ensemble) and `TraceFormatter` (log text
only) are credit-neutral.

## Per-run verdicts

| run | verdict | notes |
|---|---|---|
| 1 | **PASS** | Both switches + both branch conditions; fix at both. Located the request via the `zxid:0xfffffffffffffffe` / `txntype:unknown` fingerprint and reconstructed the client arithmetic (`readTimeout = 2/3 × 10 000 ms`) that produces the pasted line. |
| 2 | **FAIL** | Names only `CommitProcessor.needCommit()`; `FollowerRequestProcessor` appears once, purely as the component still enqueuing into the dead processor. Explains the null header as a *timing race* with a COMMIT that was in fact never requested, and prescribes a single-line fix that would leave the member dark — stalling in `nextPending` instead of crashing. |
| 3 | **PASS** | Both sites as defects, with the correct framing: three opcode classifications that disagree, `isQuorum()` on one side and the two follower-path switches on the other. Lists both edits. |
| 4 | **PASS** | Both sites + branches, plus an explicit enumeration of the full conjunction the failure needs (op is `createExt`; client is on a follower so no `PrepRequestProcessor` sets `hdr`; `isQuorum()` true; both switches missing; `cleanup()`'s `!stopped` arm). |
| 5 | **PASS** | Both sites + branches, stated as one defect — omitted from both switches while `isValid()`, `isQuorum()` and `op2String()` all list it. |

## Discussion

With the symptom reduced to a bare `ConnectionLoss` timeout line, four of five runs still
isolated both root-causing switches and prescribed exactly the upstream fix. The reasoning
was genuinely reconstructive: nothing in the prompt named the operation, the member role, or
even that a write was involved, so each run had to work backwards from a client-side timeout
through the server logs, spot the one request carrying the unset-zxid sentinel with no
preceding `Committing request` line, and then find the two switches that omit that opcode.
The crash site is two components away from either root cause and the stack trace points at
neither. Tightening the symptom did not lower the score — it changed which run failed
(previously run 3, now run 2), which suggests the variance is in the model's search, not in
how much the prompt gave away.

The failure is the informative case, and its shape repeated across both specs: a run walks
the chain correctly from the crash backwards, reaches the *first* switch that explains the
NPE, declares it the root cause, and stops. Run 2 then had to explain away the null header
and invented a plausible-sounding race with a leader COMMIT — a commit its own analysis
should have shown could never arrive, since nothing forwarded the request. One missing site
became one confident wrong mechanism, and the resulting one-line patch would have converted
a crash into a hang without curing the outage. Nothing in the run flags the gap; it reads as
confidently as the four correct ones. That is the practical problem for single-pass
diagnosis: the model is right most of the time, wrong occasionally, and equally sure either
way, so the operator cannot tell run 2 from run 4 without the answer key — which is what a
grounding tool like CLODS is meant to supply.

Two honest caveats. First, the DEBUG log is well signposted for this bug: the request type
and zxid are printed at every processor hop, which narrows the search to a few dozen lines,
and a missing enum case is the most searchable kind of defect there is. Second, the
anonymization renames `create2` to `createExt` but does not erase the model's background
knowledge — run 3 spontaneously wrote "`createExt` (i.e. `create2`, OpCode = 15)", and run 2
guessed (wrongly) that it was the TTL/container-node create. General familiarity with the
ZooKeeper wire protocol survives the rename; recognition of *this ticket* is what the rename
removes, and that familiarity did not save run 2.
