## Root cause

The new `create(path, data, acl, createMode, Stat)` overload sends the new opcode `OpCode.createExt` (see `ZooKeeper.java:1143`). The op is wired into most server code paths, but two follower-side switches were never updated to know about it. That gap turns a single `create` call into a fatal, follower-wide outage.

### The failure path

**1. The follower never forwards the request to the leader.**

`FollowerRequestProcessor.run()` — `source/src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79-100`:

```java
switch (request.type) {
case OpCode.sync:  ...
case OpCode.create:      // <-- OpCode.createExt is MISSING here
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

Because `OpCode.createExt` has no case, the switch silently falls through and `zks.getFollower().request(request)` is never called. The leader never learns of the request, so no PROPOSAL/COMMIT will ever come back for it.

**2. The CommitProcessor treats it as a "read" and dispatches it immediately, unproposed.**

`CommitProcessor.needCommit()` — `source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131-148`:

```java
protected boolean needCommit(Request request) {
    switch (request.type) {
        case OpCode.create:          // <-- OpCode.createExt is MISSING
        case OpCode.delete:
        case OpCode.setData:
        case OpCode.reconfig:
        case OpCode.multi:
        case OpCode.setACL:
            return true;
        ...
        default:
            return false;            // <-- createExt hits this branch
    }
}
```

`needCommit` returns `false`, so in `run()` (lines 172–175) the request is handed to `sendToNextProcessor(request)` right away, with `request.hdr == null` (there is no txn — nothing was proposed).

**3. FinalRequestProcessor asks the DB to persist a committed proposal that doesn't exist → NPE.**

`FinalRequestProcessor.processRequest()` — `source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:126-128`:

```java
if (request.isQuorum()) {                                   // true for createExt
    zks.getZKDatabase().addCommittedProposal(request);
}
```

`Request.isQuorum()` returns `true` for `createExt` (`Request.java:169-170`), so this branch is taken. Inside `ZKDatabase.addCommittedProposal` at `ZKDatabase.java:251`:

```java
request.getHdr().serialize(boa, "hdr");   // NPE — request.getHdr() is null
```

The log confirms this exact frame:

```
java.lang.NullPointerException
    at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
    at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
    at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
```

**4. The uncaught exception kills the CommitProcessor for the whole follower.**

`CommitProcessor.CommitWorkRequest.cleanup()` — `CommitProcessor.java:283-290`:

```java
public void cleanup() {
    if (!stopped) {
        LOG.error("Exception thrown by downstream processor, unable to continue.");
        CommitProcessor.this.halt();
    }
}
```

`WorkerService` runs `cleanup()` when `doWork()` throws. Because `stopped` is `false`, the CommitProcessor is halted. The log shows this immediately:

```
ERROR ... Exception thrown by downstream processor, unable to continue.
INFO  ... CommitProcessor exited loop!
```

### Why every other client on that follower then fails with ConnectionLoss

With the CommitProcessor thread gone, the follower's request pipeline is dead — no request from any session can be committed or replied to, and no pings can be answered. The follower's JVM is still up and `NIOServerCnxnFactory` still accepts sockets and even re-validates renewed sessions via `Learner`, but any read/write submitted after the NPE just sits until the client's read timeout fires (`ConnectionLoss`). Reconnecting to the same follower just repeats the pattern, exactly as the symptom describes. The leader and the other follower are untouched because the bad request was never forwarded off-box.

### The two missing branches to fix

- Add `case OpCode.createExt:` alongside `case OpCode.create:` in `FollowerRequestProcessor.java:84` (and, symmetrically, in `ObserverRequestProcessor.java:93`).
- Add `case OpCode.createExt:` alongside `case OpCode.create:` in `CommitProcessor.needCommit()` at `CommitProcessor.java:133`.

Either fix alone stops the NPE (the first prevents the unproposed short-circuit; the second would still be needed for correctness so `createExt` waits for the commit like every other write).
