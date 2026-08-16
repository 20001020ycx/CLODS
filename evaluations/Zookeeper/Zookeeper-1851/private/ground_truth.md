# Ground truth — Zookeeper-1851  (answer key; NEVER shown to the diagnosis LLM)

Derived from `private/fix.diff` (upstream fix commit `bcf09c846`, pre-fix
`25ea38a87`). Line numbers are those of the anonymized tree in `source/`, which is
line-for-line identical to the pre-fix tree (every M4 rewrite is token-for-token).

**Name cross-reference (METHODOLOGY §8: the LLM answers in anonymized names; translate via
`private/anonymization_map.json`).** M4 renames the failure-path files/types and rewrites the
failure-path log statements, so the answer key carries both spellings:

| real (pre-fix tree) | anonymized (what `source/` and the log show) |
|---|---|
| `create2` (opcode) | `createExt` |
| `FollowerRequestProcessor` | `FollowerIngressProcessor` |
| `ObserverRequestProcessor` | `ObserverIngressProcessor` |
| `CommitProcessor` (+ inner `CommitWorkRequest`) | `StagedRequestProcessor` (+ `StageWorkRequest`) |
| `FinalRequestProcessor` | `TerminalRequestProcessor` |
| `ZKDatabase` | `ZKStateStore` |
| `WorkerService` | `TaskExecutorPool` |
| `TraceFormatter` | `OpNameFormatter` |
| log: `Processing request:: ` | `Handling submission:: ` |
| log: `Committing request:: ` | `Applying agreed submission:: ` |
| log: `Exception thrown by downstream processor, unable to continue.` | `Downstream stage failed; cannot continue.` |
| log: `CommitProcessor exited loop!` | `StagedRequestProcessor loop terminated` |
| log: `Client session timed out, have not heard from server in ` | `Session inactive - no server traffic for ` |

Method/field names are **not** renamed: `needCommit`, `isQuorum`, `addCommittedProposal`,
`processRequest`, `halt`, `nextPending`, `sendToNextProcessor` read the same in both trees.
Below, sites are named in **anonymized** form (as a run will name them), with the real name
in parentheses.

## What the fix changed

The fix adds a single missing `case OpCode.createExt:` label to each of four opcode
switches. All four hunks are one-line additions; nothing else changes.

| # | file (in `source/`) | line | what the fix inserts | on the reproduced failure path? |
|---|---|---|---|---|
| 1 | `…/server/quorum/FollowerIngressProcessor.java` (real: `FollowerRequestProcessor.java`) | 84 (before `case OpCode.create:`) | `case OpCode.createExt:` in `run()`'s forward-to-leader switch | **yes — primary** |
| 2 | `…/server/quorum/StagedRequestProcessor.java` (real: `CommitProcessor.java`) | 133 (before `case OpCode.create:`) | `case OpCode.createExt:` in `needCommit()` | **yes — primary** |
| 3 | `…/server/quorum/ObserverIngressProcessor.java` (real: `ObserverRequestProcessor.java`) | 93 (before `case OpCode.create:`) | `case OpCode.createExt:` in `run()`'s forward-to-leader switch | no (identical defect on the observer variant; the reproduction ensemble has no observer) |
| 4 | `…/server/OpNameFormatter.java` (real: `TraceFormatter.java`) | 36-37 (before `case OpCode.create:`) | `case OpCode.createExt: return "createExt";` | no (trace/log formatting only, no behavioural effect) |

## The exact root-causing lines and branch conditions

### Site 1 — the write is never forwarded to the leader
`FollowerIngressProcessor.run()` (real: `FollowerRequestProcessor.run()`), lines 79-92:

```java
switch (request.type) {
case OpCode.sync:                      // 80
    zks.pendingSyncs.add(request);
    zks.getFollower().request(request);
    break;
case OpCode.create:                    // 84  <-- the fix adds `case OpCode.createExt:` here
case OpCode.delete:
case OpCode.setData:
case OpCode.reconfig:
case OpCode.setACL:
case OpCode.multi:
case OpCode.check:
    zks.getFollower().request(request); // 91  <-- never reached for a createExt request
    break;
...                                     // no default: -> a createExt falls out silently
}
```

**Wrong branch condition:** the set of opcodes that select the
`zks.getFollower().request(request)` arm omits `OpCode.createExt`, and the switch has no
`default:` arm. So for `request.type == OpCode.createExt` **no case matches**, the write is
never shipped to the leader, and no proposal/commit for it will ever come back — even
though line 72 (`nextProcessor.processRequest(request)`, executed just above the switch)
has already queued the request into the `StagedRequestProcessor`.

### Site 2 — the queued write is then treated as a read
`StagedRequestProcessor.needCommit()` (real: `CommitProcessor.needCommit()`), lines 131-148:

```java
protected boolean needCommit(Request request) {
    switch (request.type) {
        case OpCode.create:            // 133 <-- the fix adds `case OpCode.createExt:` here
        case OpCode.delete:
        case OpCode.setData:
        case OpCode.reconfig:
        case OpCode.multi:
        case OpCode.setACL:
            return true;
        ...
        default:
            return false;              // 146 <-- createExt takes this arm
    }
}
```

**Wrong branch condition:** `OpCode.createExt` is not in the "needs a commit" set, so
`needCommit()` returns **false** via `default:`. In `StagedRequestProcessor.run()` the guard
`if (needCommit(request)) { nextPending.set(request); } else { sendToNextProcessor(request); }`
therefore takes the **else** arm and hands the write straight to `TerminalRequestProcessor`
as if it were a read — with `request.getHdr() == null`, because no leader transaction
ever arrived (site 1).

### Consequence (explanatory; not itself a required answer)
`TerminalRequestProcessor.processRequest` (real: `FinalRequestProcessor`) then runs with a
null header and reaches `if (request.isQuorum())` (line 126) — `Request.isQuorum()` *does*
list `OpCode.createExt` and returns true — so it calls
`ZKStateStore.addCommittedProposal(request)` (real: `ZKDatabase`), whose line 251 does
`request.getHdr().serialize(boa, "hdr")` → **NullPointerException**. The exception escapes
`StagedRequestProcessor$StageWorkRequest.doWork`, so `TaskExecutorPool` (real:
`WorkerService`) invokes `StageWorkRequest.cleanup()`, which logs *"Downstream stage failed;
cannot continue."* and calls `StagedRequestProcessor.halt()`. The follower's staging pipeline
exits (*"StagedRequestProcessor loop terminated"*), so that member never answers another
request — which is why every client on it is disconnected, and why the clients eventually log
*"Session inactive - no server traffic for 6666ms …"* and surface `ConnectionLoss`.

## Grading rule (see METHODOLOGY.md §8)

A run **PASSes** iff it names **both primary sites with their branch conditions**:

1. **`FollowerIngressProcessor.run()`'s `switch (request.type)`** (real:
   `FollowerRequestProcessor`; the forward-to-leader switch, ~line 79-92): the missing
   `case OpCode.createExt:` on the arm that calls `zks.getFollower().request(request)`,
   i.e. the request is never forwarded to the leader.
2. **`StagedRequestProcessor.needCommit()`** (real: `CommitProcessor`; ~line 131-147):
   `OpCode.createExt` falls to
   `default: return false`, so the write is dispatched as a read (to
   `TerminalRequestProcessor` with no transaction) instead of waiting for a commit.

Both are required because neither alone accounts for the symptom, and neither alone is a
sufficient fix:

- Site 1 is why **the znode is never created anywhere in the ensemble** and why no commit
  can ever arrive for the request.
- Site 2 is why the header-less request is dispatched to `TerminalRequestProcessor`
  *immediately*, which is what produces the NPE that kills the pipeline.
- Had only site 2's case been missing (forwarding intact), the follower would still have
  dispatched the request before the leader's commit could arrive → same NPE.
- Had only site 1's case been missing (`needCommit` correct), the request would have been
  parked in `nextPending` and waited forever → the follower still goes dark, but by
  stalling, with no NPE.

So a run that names only `needCommit()` prescribes a fix that leaves the member broken (it
would hang rather than crash), and a run that names only the forwarding switch does not
explain the NPE. Naming the file but not the specific switch/branch is a FAIL; naming the NPE
site (`ZKStateStore:251` / `TerminalRequestProcessor:127`) *instead of* the two switches is a
FAIL (that is the crash site, not the root cause).

**Not required** (credit-neutral if mentioned, no penalty if omitted):
`ObserverIngressProcessor` (same defect, not exercised — the ensemble has no observer) and
`OpNameFormatter` (log formatting only). Line numbers may differ in the answer; match by code
identity, and accept either the anonymized or the real name via the cross-reference above.
