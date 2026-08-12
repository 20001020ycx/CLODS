## Root cause

The follower `myid:1` receives a client request with `OpCode.createExt` (a new opcode this branch adds alongside the classic `OpCode.create`). Two code paths in the follower's request pipeline were never taught about `createExt`, so the request slips into `FinalRequestProcessor` with no txn header, `ZKDatabase.addCommittedProposal` NPEs on it, `CommitProcessor` dies, and every subsequent request (including pings) is silently dropped — so all clients attached to this follower hit `ClientCnxn`'s read-timeout (~2/3 of the 10 s negotiated timeout ≈ 6.67 s) and surface `KeeperException.ConnectionLoss`.

## The exact failure path

**1. `CommitProcessor.needCommit()` — missing case (`source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131-148`)**
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
            return false;         // <-- OpCode.createExt lands here
    }
}
```
Because `createExt` falls into the `default` branch and returns `false`, the main loop at `CommitProcessor.java:172-176` treats it as a read and calls `sendToNextProcessor(request)` immediately, instead of parking it in `nextPending` to wait for the leader's commit.

**2. `FollowerRequestProcessor.run()` — missing case (`source/src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79-100`)**
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
    zks.getFollower().request(request);   // forward to leader
    break;
...
}   // <-- no case for OpCode.createExt, so it is never forwarded
```
`createExt` is a quorum op (`Request.isQuorum()` returns `true` for it at `Request.java:170`), but the follower never ships it to the leader, so no `PROPOSAL/COMMIT` ever comes back with a populated `TxnHeader`.

**3. `FinalRequestProcessor.processRequest` — the null header still triggers `addCommittedProposal` (`source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:108-128`)**
```java
if (request.getHdr() != null) { ... }        // skipped: hdr is null
...
if (request.isQuorum()) {                    // true for createExt (Request.java:170)
    zks.getZKDatabase().addCommittedProposal(request);
}
```
The log line at `01:41:52,263` — `type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/failing/with-stat` — is the visible fingerprint: `zxid = -2` is the sentinel value `Request.zxid` retains when no proposal was assigned, and `txntype:unknown` means `request.getHdr()` is `null`.

**4. NPE at `ZKDatabase.addCommittedProposal` (`source/src/java/main/org/apache/zookeeper/server/ZKDatabase.java:235-268`)**
```java
public void addCommittedProposal(Request request) {
    ...
    try {
        request.getHdr().serialize(boa, "hdr");     // line 251  → NullPointerException
```
Reported in the log exactly as
```
java.lang.NullPointerException
    at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
    at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
    at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
```

**5. `CommitProcessor` self-halts on the downstream failure (`CommitProcessor.java:283-290, 346-350`)**
```java
public void cleanup() {
    if (!stopped) {
        LOG.error("Exception thrown by downstream processor, unable to continue.");
        CommitProcessor.this.halt();      // sets stopped=true, clears queues
    }
}
```
Matching log evidence at `01:41:52,264`:
```
ERROR [CommitProcWorkThread-2:CommitProcessor$CommitWorkRequest@286] - Exception thrown by downstream processor, unable to continue.
INFO  [CommitProcessor:1:CommitProcessor@191] - CommitProcessor exited loop!
```

**6. Client-visible symptom.** Once `stopped == true`, `CommitProcessor.processRequest` (line 333-344) short-circuits every subsequent request, including pings. On the client side, `ClientCnxn.SendThread` computes its read timeout as roughly `readTimeout = sessionTimeout * 2/3` (10 000 ms × 2/3 ≈ 6666 ms). With no server traffic, exactly that threshold fires and the session is torn down with `ConnectionLoss`:
```
01:41:58,930 ... Client session timed out, have not heard from server in 6670ms for sessionid 0x19ff3a1f9800001
```
The follower is still accepting TCP connections (its `NIOServerCnxnFactory` is untouched), so reconnecting clients keep landing on `myid:1`, get their session revalidated by the leader (`Learner@115 Revalidating client`), and then time out again in the next ~6.67 s — reproducing the `ConnectionLoss` loop seen from `01:41:58` onward.

## Fix

Add `OpCode.createExt` to the `true`-returning arm of `CommitProcessor.needCommit()` (CommitProcessor.java:139) and to the leader-forwarding switch in `FollowerRequestProcessor.run()` (FollowerRequestProcessor.java:90). Defensively, `ZKDatabase.addCommittedProposal` should also guard against a null `request.getHdr()` (e.g., early-return, mirroring the null-check already present in `FinalRequestProcessor.java:108`), so a future missed opcode cannot silently kill the CommitProcessor.
