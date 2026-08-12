## Root cause

`OpCode.createExt` (the opcode used by the `create(..., Stat)` overload — see `ZooKeeper.java:1143` and `1208`) is missing from **two** switch statements on the follower's write pipeline. That gap causes the follower's `CommitProcessor` thread to die on the first such request, so the follower silently stops processing anything from any client.

The failure walks through four code sites, in order:

### 1. `FollowerRequestProcessor.run()` — request is never forwarded to the leader
`source/src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79-100`

```java
switch (request.type) {
case OpCode.sync: ...
case OpCode.create:
case OpCode.delete:
case OpCode.setData:
case OpCode.reconfig:
case OpCode.setACL:
case OpCode.multi:
case OpCode.check:
    zks.getFollower().request(request);
    break;
...
}
```
There is no `case OpCode.createExt:`. The request is enqueued to `CommitProcessor` (line 72) but never shipped to the leader, so no PROPOSAL/COMMIT will ever arrive back for it.

### 2. `CommitProcessor.needCommit()` — request is not held for its commit
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
            return false;
    }
}
```
Again, no `OpCode.createExt`, so `needCommit()` returns `false` (the `default:` branch). The main loop at line 172 therefore does **not** set `nextPending`; it falls through to `sendToNextProcessor(request)` (line 175), delivering an uncommitted request — with `hdr == null`, `txn == null`, `zxid == 0xfffffffffffffffe` — straight to `FinalRequestProcessor`.

You can see both effects in the log:
```
1873 [FollowerRequestProcessor:1:CommitProcessor@338] Processing request:: … type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown …
1874 [CommitProcWorkThread-2:FinalRequestProcessor@91]  Processing request:: … type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown …
```
(no intervening `Committing request:: … type:create…` line, unlike every previous op).

### 3. `FinalRequestProcessor.processRequest()` — NPE while indexing the "committed proposal"
`source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:126-128`

```java
if (request.isQuorum()) {
    zks.getZKDatabase().addCommittedProposal(request);
}
```
`Request.isQuorum()` explicitly returns `true` for `OpCode.createExt` (`Request.java:170`), so `addCommittedProposal` is called even though nothing was actually committed. Inside:

`source/src/java/main/org/apache/zookeeper/server/ZKDatabase.java:251`

```java
request.getHdr().serialize(boa, "hdr");   // NPE — hdr was never populated
```
This is exactly the exception in the log:
```
1875-1883 java.lang.NullPointerException
    at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
    at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
    at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
    at org.apache.zookeeper.server.WorkerService$ScheduledWorkRequest.run(WorkerService.java:161)
```

### 4. `CommitWorkRequest.cleanup()` — the exception kills the CommitProcessor
`source/src/java/main/org/apache/zookeeper/server/WorkerService.java:161-165`

```java
try { workRequest.doWork(); }
catch (Exception e) { LOG.warn("Unexpected exception", e); workRequest.cleanup(); }
```

`source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:284-290`

```java
public void cleanup() {
    if (!stopped) {
        LOG.error("Exception thrown by downstream processor, unable to continue.");
        CommitProcessor.this.halt();      // stopped=true; clear queue; stop workerPool
    }
}
```
`halt()` (line 346) sets `stopped = true`, wakes the main loop, clears `queuedRequests`, and shuts down the worker pool. The `while (!stopped)` at `CommitProcessor.java:154` immediately exits — see log line 1885: `CommitProcessor exited loop!`.

### Why the whole follower goes dark after that
`NIOServerCnxnFactory` keeps accepting sockets and handing bytes to `FollowerRequestProcessor.processRequest`, which happily pushes them into the follower's `CommitProcessor.queuedRequests` (line 340). But the **only** thread that drains that queue — the `CommitProcessor` main loop — is gone. So no request past that point is ever acked by any downstream processor, no response is written back on the wire, and every session on this follower eventually hits its read timeout with `ConnectionLoss`. Session re-establishment succeeds at the NIO layer (see log 1892-1901 `Established session …`), but the very next real request meets the same dead queue and times out again — exactly the symptom described. Meanwhile the leader and the other follower are unaffected because they never received the request in the first place.

### The specific branches to fix
Add `case OpCode.createExt:` (falling into the same body as `OpCode.create`) to:
1. `FollowerRequestProcessor.run()` switch at `FollowerRequestProcessor.java:84` — so the request is forwarded to the leader.
2. `CommitProcessor.needCommit()` switch at `CommitProcessor.java:133` — so it returns `true` and the request is held in `nextPending` until the leader's COMMIT arrives.

Fixing either one alone would prevent the crash (either the request reaches the leader and returns with a valid hdr, or it is held and never reaches `FinalRequestProcessor` prematurely), but both switches are conceptually incomplete and both need `OpCode.createExt` added for the write-path invariants to hold.
