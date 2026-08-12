# Zookeeper-1851 — LLM diagnosis result

| field | value |
|---|---|
| bug id | `Zookeeper-1851` |
| system | Apache ZooKeeper, trunk @ 2014-07 (3.5.0-SNAPSHOT) |
| fix commit | `bcf09c846` (pre-fix `25ea38a87`) |
| subject | Claude Opus 4.7, effort `high`, single turn, no internet |
| **result** | **4 / 5 PASS** |

## Symptom

A client connected to a **follower** calls the create overload that also returns the new
node's `Stat`. The call never completes — `ConnectionLoss` after the client's read timeout —
and the znode is created nowhere in the ensemble. From that instant the follower answers
*nothing*: every other client on it fails the same way, sessions are re-established with it
and time out again, while its process stays up and the rest of the ensemble is healthy.
A plain create on the same connection had succeeded 8 ms earlier.

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

Downstream (not itself required in an answer): `Request.isQuorum()` *does* list `createExt`,
so `FinalRequestProcessor` calls `ZKDatabase.addCommittedProposal()`, whose
`request.getHdr().serialize(...)` throws NPE; `WorkerService` runs
`CommitWorkRequest.cleanup()`, which halts the `CommitProcessor` for good.

The other two hunks — `ObserverRequestProcessor` (no observer in the ensemble) and
`TraceFormatter` (log text only) — are credit-neutral.

## Per-run verdicts

| run | verdict | notes |
|---|---|---|
| 1 | **PASS** | Both switches + both branch conditions; derived the full NPE→`halt()` chain and cited the discriminating log evidence (no `Committing request` line, `zxid:0xfffffffffffffffe`, `txntype:unknown`). |
| 2 | **PASS** | Both sites, and states the fix as `case OpCode.createExt:` at `FollowerRequestProcessor.java:84` and `CommitProcessor.java:133` — exactly the real patch. Aside that either fix alone would suffice is imprecise. |
| 3 | **FAIL** | Names only `CommitProcessor.needCommit()`. `FollowerRequestProcessor` appears zero times; it attributes the missing forward-to-leader step to the `needCommit` defect, which is a different switch executed earlier. Its one-line fix would leave the follower dark — stalled in `nextPending` awaiting a commit that can never arrive. |
| 4 | **PASS** | Both sites + branches, plus the control contrast (the plain create used `OpCode.create`, which *is* in both switches) and the observation that `addCommittedProposal` sits outside `FinalRequestProcessor`'s try/catch. |
| 5 | **PASS** | Both sites + branches, listed as "the two missing branches to fix"; also spotted the identical omission in `ObserverRequestProcessor`. Closing aside about either fix alone is imprecise. |

## Discussion

Four of five runs isolated the defect exactly, and they did it by *reasoning from the
evidence* rather than by pattern-matching a symptom: each one noticed that the failing
request carried the unset-zxid sentinel and no `Committing request` line, walked the
follower's three-stage pipeline, and found the two opcode switches that omit the new
operation. That is a genuinely hard multi-file inference — the crash site
(`ZKDatabase:251`) is two components away from either root cause, and the stack trace
points at neither. It is also, however, a case where the evidence is unusually
well-signposted: a DEBUG log that prints the request type and zxid at every processor hop
narrows the search to a few dozen lines, and the fix is a missing enum case, which is the
most searchable kind of defect there is.

The failure is the more interesting data point. Run 3 followed the same chain but stopped
at the first switch it found, declared it "the primary defect", and asserted that the
non-forwarding was a *consequence* of that misclassification — a causal inversion that
sounds coherent and would have shipped a patch leaving the follower just as unusable, now
hanging instead of crashing. Nothing in the run's own reasoning flags the gap; it reads
exactly as confidently as the four correct ones. That is the failure mode that matters for
the paper's argument: not that the model cannot find root causes, but that a single
unverified pass gives no signal about which of its answers is the incomplete one, and the
incomplete answer is the one that still passes review. Determinism here is 4/5, not 5/5, and
the operator has no way to tell run 3 from run 4 without the ground truth — which is
precisely what a tool like CLODS is meant to supply.

One honest caveat on the anonymization: `create2` was renamed to `createExt` throughout,
yet two runs (3 and one earlier discarded attempt) spontaneously referred to the opcode as
"create2". The model retains general familiarity with the ZooKeeper wire protocol, so the
rename removes the ticket's string handle but not the model's background knowledge of the
system. Notably, that familiarity did **not** rescue run 3's diagnosis.
