Based on my log analysis and code review, here's the root cause:

## Failure Path Summary

**Client-visible failure** (`ClientCnxn.java` in `SendThread.run()`):

```java
// Line 1150
to = readTimeout - clientCnxnSocket.getIdleRecv();
...
// Lines 1155-1161  ← the throw that produces the log message
if (to <= 0) {
    throw new SessionTimeoutException(
        "Session inactive - no server traffic for "
            + clientCnxnSocket.getIdleRecv() + "ms"
            + " for sessionid 0x"
            + Long.toHexString(sessionId));
}
```

Caught at `ClientCnxn.java:1206‑1207` (the `e instanceof SessionTimeoutException` branch that emits `RETRY_CONN_MSG`), which then runs `cleanup()` and queues a `Disconnected` event. Any in-flight or subsequently issued operation on that session returns `KeeperException.ConnectionLoss`.

This branch fires because `now - lastHeard` exceeded `readTimeout` (≈ 6666 ms for the negotiated 10 s session): **the server stopped sending anything back — not even ping responses**.

## Why the server stops responding

The client is pinned to server 1 (127.0.0.1:24551, a follower in the ensemble with leader = sid 3). Grepping the log confirms the follower falls silent in bursts: e.g.

```
myid:1 QuorumPeer[…]/24551:StagedRequestProcessor@325 - Applying agreed submission … zxid:0x1000002cb   @ 18:49:25.075
     ← nothing at all for 5m43s ←
myid:1 QuorumPeer[…]/24551:ZooKeeperServer@619 - Established session 0x1a008cd5e440000 …               @ 18:55:08.546
```

Meanwhile on the leader:
```
myid:3 LearnerHandler-/127.0.0.1:36410:Leader@806 - outstanding is 0                                    @ 18:49:27.825   (sid=1 acked 0x1000002cc late)
myid:3 LearnerHandler-/127.0.0.1:36410:StagedRequestProcessor@325 - Applying agreed submission … 0x1000002cd @ 18:55:08.838
```

So the follower's `QuorumPeer` / `Follower.followLeader()` thread — the same thread that would call `fzk.commit(zxid) → stagedRequestProcessor.commit(request)` and log "Applying agreed submission" — is completely stuck: no PROPOSALs, no COMMITs, no PINGs are being consumed from the leader socket. It resumes only after a fresh client TCP reconnect drives a REVALIDATE round‑trip that unblocks the socket.

## The exact code branch that turns this stall into a client `ConnectionLoss`

`StagedRequestProcessor.java` — the follower's commit processor — will service reads and pings only when it is **not** waiting for a write commit. The relevant branches:

```java
// StagedRequestProcessor.run(), lines 169-177
while (!stopped && !isWaitingForCommit() &&        //  ←  BLOCKING GUARD
       !isProcessingCommit() &&
       (request = queuedRequests.poll()) != null) {
    if (needCommit(request)) {
        nextPending.set(request);                  //  a write pins the pipeline
    } else {
        sendToNextProcessor(request);              //  only reached when nextPending == null
    }
}
```

with

```java
// StagedRequestProcessor.java:131-148
protected boolean needCommit(Request request) {
    switch (request.type) {
        case OpCode.create:  case OpCode.delete:
        case OpCode.setData: case OpCode.reconfig:
        case OpCode.multi:   case OpCode.setACL:
            return true;              //  ← every write from the workload
        case OpCode.sync:
            return matchSyncs;        //  matchSyncs=true on follower
        case OpCode.createSession:
        case OpCode.closeSession:
            return !request.isLocalSession();
        default:
            return false;
    }
}
```

and the guard predicates at `StagedRequestProcessor.java:119-129`:

```java
private boolean isWaitingForCommit()   { return nextPending.get() != null; }
private boolean isProcessingCommit()   { return currentlyCommitting.get() != null; }
private boolean isProcessingRequest()  { return numRequestsProcessing.get() != 0; }
```

Sequence for the affected session (0x1a008cd5e440000):

1. Client posts a `create` (write). `FollowerIngressProcessor.run()` enqueues it into `StagedRequestProcessor.queuedRequests` **and** forwards it to the leader via `zks.getFollower().request(request)` (`FollowerIngressProcessor.java:72,79‑92`).
2. `StagedRequestProcessor.run()` polls it, `needCommit(...)` returns `true`, so `nextPending.set(request)` executes (line 173). From that instant `isWaitingForCommit()` is true.
3. The inner `while` at line 169 will not poll any more work — reads, pings from *any* session, or other writes — because of the `!isWaitingForCommit()` guard. `processCommitted()` (line 198‑242) also short‑circuits: with `nextPending` set, it only advances when a *matching* commit arrives via `commit(Request)` (line 320‑331).
4. `StagedRequestProcessor.commit(...)` is invoked only from `FollowerZooKeeperServer.commit(long)` (line 97‑112), which is only invoked from `Follower.processPacket()`'s `case Leader.COMMIT` branch (line 136‑138). Because the follower's `QuorumPeer`/`Follower` thread is stalled inside `Follower.followLeader()`'s `readPacket / processPacket` loop (line 87‑90), no `COMMIT` is ever delivered — so `nextPending` is never cleared and `committedRequests` stays empty.
5. Everything the client sends afterwards (further ops or the keep‑alive pings that `SendThread` emits every `readTimeout/2` ms) reaches `NIOServerCnxn.doIO → readRequest → FollowerIngressProcessor.processRequest → StagedRequestProcessor.processRequest` and lands in `queuedRequests`, but the guard above refuses to dequeue any of them.
6. With no server-generated bytes hitting the client socket for `readTimeout` ms, the client's own `SendThread` runs `to = readTimeout - getIdleRecv()` → `to ≤ 0` at `ClientCnxn.java:1155`, and throws `SessionTimeoutException` → logged with the "Session inactive - no server traffic for 6666ms" message at line 1207, followed by `cleanup()` (line 1221) which fails every packet in `pendingQueue`/`outgoingQueue` via `conLossPacket(p)` (`StagedRequestProcessor.cleanup` around line 1295 in `ClientCnxn`), returning `ConnectionLoss` to the application.

## Root cause (single sentence)

`StagedRequestProcessor` blocks the entire request pipeline behind the first write it takes as `nextPending` — the `!isWaitingForCommit()` guard on line 169 of `StagedRequestProcessor.run()` (with `needCommit()` returning `true` for the workload's writes on line 133) means no pings or reads can be answered until `Follower.processPacket()`'s `Leader.COMMIT` branch (line 137, calling `FollowerZooKeeperServer.commit → stagedRequestProcessor.commit`) fires; when the follower's single `QuorumPeer/Follower.followLeader()` thread is unable to drain COMMIT packets promptly, that pending write pins the pipeline, the client sees `readTimeout - getIdleRecv() ≤ 0` at `ClientCnxn.java:1155` and throws `SessionTimeoutException`, which the caller surfaces as `KeeperException.ConnectionLoss`.
