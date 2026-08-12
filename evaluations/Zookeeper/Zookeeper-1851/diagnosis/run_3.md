## Root Cause

The failing session's requests never see a response because the **follower's CommitProcessor thread dies with a NullPointerException** the moment it processes the first `createExt` (i.e. `create2`, OpCode = 15) request, after which no more requests on that server are ever dispatched to `FinalRequestProcessor`. Every subsequent client ping/read/write hangs, and the client-side `SendThread` fires the "have not heard from server in 6670 ms" timeout at `readTimeout = 2/3 · sessionTimeout` (≈ 6666 ms for the negotiated 10 s), closing the socket and throwing `KeeperException.ConnectionLoss`.

Server-side proof, taken directly from `logs/symptom.log` around the moment client `0x19ff3a1f9800001` starts hanging:

```
01:41:52,263 [CommitProcWorkThread-2:FinalRequestProcessor@91]
  Processing request:: sessionid:0x19ff3a1f9800001 type:createExt cxid:0x4
  zxid:0xfffffffffffffffe    ← header/zxid never assigned
01:41:52,263 [CommitProcWorkThread-2:WorkerService$ScheduledWorkRequest@163]
  Unexpected exception
    java.lang.NullPointerException
      at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
      at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
      at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
01:41:52,264 [CommitProcWorkThread-2:CommitProcessor$CommitWorkRequest@286]
  Exception thrown by downstream processor, unable to continue.
01:41:52,264 [CommitProcessor:1:CommitProcessor@191] CommitProcessor exited loop!
```

## The exact branches that dictate the failure

The bug is an inconsistent set of switch statements: three separate places classify request opcodes and they disagree about `OpCode.createExt` (=15). One place (`Request.isQuorum` and `FinalRequestProcessor`) treats it as a write; the two places responsible for making writes actually work on a follower (`FollowerRequestProcessor.run` and `CommitProcessor.needCommit`) forgot to enumerate it.

### 1. Follower never forwards `createExt` to the leader — `FollowerRequestProcessor.run` switch is missing the case

`source/src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79-100`

```java
switch (request.type) {
case OpCode.sync:          ... zks.getFollower().request(request); break;
case OpCode.create:
case OpCode.delete:
case OpCode.setData:
case OpCode.reconfig:
case OpCode.setACL:
case OpCode.multi:
case OpCode.check:
    zks.getFollower().request(request);
    break;
case OpCode.createSession:
case OpCode.closeSession:
    if (!request.isLocalSession()) zks.getFollower().request(request);
    break;
}
```

`OpCode.createExt` falls to the implicit `default` — the follower **never** ships it to the leader, so the leader never proposes/commits it, and no `PROPOSAL`/`COMMIT` for that cxid ever comes back to populate `request.hdr`/`request.txn`.

### 2. `CommitProcessor.needCommit` also misses `createExt`

`source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131-148`

```java
protected boolean needCommit(Request request) {
    switch (request.type) {
        case OpCode.create:
        case OpCode.delete:
        case OpCode.setData:
        case OpCode.reconfig:
        case OpCode.multi:
        case OpCode.setACL:
            return true;
        ...
        default:
            return false;      // ← createExt falls here
    }
}
```

Because `needCommit()` returns `false` for `createExt`, the run loop at line 172–176 takes the **read-like fast path** `sendToNextProcessor(request)` instead of the `nextPending.set(request)` (wait-for-commit) branch. The request is handed to `FinalRequestProcessor` immediately, still carrying `hdr = null` and `zxid = 0xFFFFFFFFFFFFFFFE` (the "not yet committed" sentinel visible in the log).

### 3. But `FinalRequestProcessor` and `Request.isQuorum` still think it is a write

`source/src/java/main/org/apache/zookeeper/server/Request.java:161-185` (`isQuorum`) explicitly lists `case OpCode.createExt: return true;` at line 170.

`source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:126-128`:

```java
// do not add non quorum packets to the queue.
if (request.isQuorum()) {                                   // true for createExt
    zks.getZKDatabase().addCommittedProposal(request);      // line 127
}
```

That branch is taken, and control lands in:

`source/src/java/main/org/apache/zookeeper/server/ZKDatabase.java:235-269`:

```java
public void addCommittedProposal(Request request) {
    ...
    try {
        request.getHdr().serialize(boa, "hdr");   // line 251 — NPE
        if (request.getTxn() != null) { ... }
        ...
```

`request.getHdr()` is `null` (never populated by `CommitProcessor.processCommitted()` at lines 226–228, because the request never went through the wait-for-commit path and no commit ever arrived), so line 251 throws `NullPointerException`.

### 4. The NPE kills the CommitProcessor for good — `CommitWorkRequest.cleanup` → `halt`

`source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:283-290`:

```java
@Override
public void cleanup() {
    if (!stopped) {                                      // true
        LOG.error("Exception thrown by downstream processor,"
                  + " unable to continue.");
        CommitProcessor.this.halt();                     // line 288
    }
}
```

`halt()` (lines 346-353) sets `stopped = true`, clears `queuedRequests`, and stops the worker pool. The main loop at line 154 (`while (!stopped)`) exits — "CommitProcessor exited loop!" at line 191.

### 5. Once CommitProcessor is dead every client request stalls → session timeout on the client

After that instant, `CommitProcessor.processRequest()` at line 333-336 short-circuits (`if (stopped) return;`), so nothing — including client pings — ever reaches `FinalRequestProcessor`. On the client side, `ClientCnxn.SendThread`'s `readTimeout` (2/3 of the negotiated 10 s session ≈ 6666 ms) elapses without any packet from the server; the log line `ClientCnxn$SendThread@1207 - Client session timed out, have not heard from server in 6670ms … closing socket connection and attempting reconnect` is emitted. The subsequent `Learner.validateSession` succeeds against the leader (session revalidation bypasses the dead CommitProcessor — that is why the log shows repeated successful "Established session … negotiated timeout = 10000"), but the very next request on the reconnected socket hits the same dead CommitProcessor on the follower, times out again, and the loop repeats until the caller finally sees `KeeperException.ConnectionLoss`.

## Fix locus (specific lines)

Any one of these three switches has to gain `case OpCode.createExt`, and for correctness all three must agree:

- `FollowerRequestProcessor.java:79-100` — add `case OpCode.createExt:` alongside `OpCode.create` so writes are forwarded to the leader.
- `CommitProcessor.java:131-148` (`needCommit`) — add `case OpCode.createExt: return true;` so the request waits for a commit and its header gets populated at `CommitProcessor.java:226-228`.
- (Consistency) `Request.java:161` already treats it as a quorum op; `FinalRequestProcessor.java` already handles it in its response-generation switch — those don't need changing, but they are what turns the classification omission upstream into the fatal NPE at `ZKDatabase.java:251`.
