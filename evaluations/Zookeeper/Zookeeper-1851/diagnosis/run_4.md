## Root cause

`OpCode.createExt` is an intended write op (server treats it as a quorum op — `Request.isQuorum()` returns `true` for it at `source/src/java/main/org/apache/zookeeper/server/Request.java:170`), but two switch statements on the *follower* request pipeline forgot to enumerate it. As a result a `createExt` request never leaves the follower to reach the leader, and is executed locally with `hdr == null`, causing an NPE that kills the follower's `CommitProcessor`. Once `CommitProcessor` exits, the follower answers nothing (not even pings), and every client bound to that server times out with `ConnectionLoss`.

## Exact code path

Log evidence, follower `myid:1`:
```
CommitProcessor@338 - Processing request:: ... type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/failing/with-stat
FinalRequestProcessor@91 - Processing request:: ... type:createExt ... zxid:0xfffffffffffffffe ...
WorkerService$ScheduledWorkRequest@163 - Unexpected exception
java.lang.NullPointerException
    at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
    at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
    at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
CommitProcessor$CommitWorkRequest@286 - Exception thrown by downstream processor, unable to continue.
CommitProcessor@191 - CommitProcessor exited loop!
```

Note `zxid:0xfffffffffffffffe` (= -2, the "unset" sentinel) and `txntype:unknown` — the request never got a `TxnHeader`.

Step-by-step through the source:

1. **`FollowerRequestProcessor.run()` — `source/src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79-100`.** The switch that decides which types to ship to the leader lists `create/delete/setData/reconfig/setACL/multi/check` (and `sync`, `createSession`, `closeSession`) but **not** `OpCode.createExt`. The request therefore falls through the switch's default (no case) and `zks.getFollower().request(request)` at line 91 is never called. The line-72 `nextProcessor.processRequest(request)` still queues it into the local `CommitProcessor`. Because there is no PrepRequestProcessor on a follower, no one has set the request's header, so `request.hdr` is still `null` and `request.zxid` is still `-2`.

2. **`CommitProcessor.needCommit()` — `source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131-148`.** This switch also omits `OpCode.createExt`, so `needCommit()` hits the `default` at line 145 and returns `false`. In `run()` at line 169-177, the branch taken is line 175 `sendToNextProcessor(request)` — the request is dispatched to the next processor immediately, without ever waiting for a matching COMMIT from the leader.

3. **`FinalRequestProcessor.processRequest()` — `source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:126-128`.** Inside the `outstandingChanges` monitor:
   ```java
   if (request.isQuorum()) {                              // true for createExt (Request.java:170)
       zks.getZKDatabase().addCommittedProposal(request); // hdr is null here
   }
   ```
   The `isQuorum()` branch is taken, so `addCommittedProposal` is called on a request whose `hdr` field is `null`. The earlier `zks.processTxn(request)` on line 104 also skips its work because the header is null, but does not throw — the NPE happens next.

4. **`ZKDatabase.addCommittedProposal()` — `source/src/java/main/org/apache/zookeeper/server/ZKDatabase.java:235-269`.** Line 251:
   ```java
   request.getHdr().serialize(boa, "hdr");
   ```
   `request.getHdr()` is `null`, so a `NullPointerException` is thrown. This is exactly the frame at the top of the stack trace.

5. **`CommitProcessor$CommitWorkRequest` — `source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:276-290`.** `doWork()` calls `nextProcessor.processRequest(request)` at line 294 and the NPE propagates out. `WorkerService$ScheduledWorkRequest` catches it and invokes `cleanup()`, which enters the `if (!stopped)` branch at line 285-289 and executes `CommitProcessor.this.halt()`. The `run()` loop then breaks out and logs `"CommitProcessor exited loop!"` at line 191.

6. **Downstream effect on the client.** With `CommitProcessor` halted, follower `myid:1` no longer forwards *any* request to `FinalRequestProcessor`, including pings. `ClientCnxn` heartbeats therefore go unanswered; after `2/3 * sessionTimeout` (~6.6 s of the 10 s negotiated timeout observed in the log at `ZooKeeperServer@619`), `ClientCnxn$SendThread` at line 1207 emits the exact message quoted in the report:
   ```
   Client session timed out, have not heard from server in 6670ms ... closing socket ... reconnect
   ```
   which is surfaced to the caller as `KeeperException.ConnectionLoss`. The subsequent log lines confirm the pattern repeats: the client reconnects, re-sends its outstanding write, the follower re-hits the same trap on the next `createExt`, and times out again.

## The specific triggering conditions (branches)

The failure requires **all** of the following to hold simultaneously:

- Request type is `OpCode.createExt` (client used the extended create op — path `/app/failing/with-stat` in the log).
- The client is connected to a **follower** (so `FollowerRequestProcessor` is the head of the chain and no `PrepRequestProcessor` sets `hdr`).
- `Request.isQuorum()` returns `true` for the type (`Request.java:161-185`, case at line 170), which drives `FinalRequestProcessor.java:126` into calling `addCommittedProposal`.
- `FollowerRequestProcessor.java:79-100` switch has **no `case OpCode.createExt`**, so the request is not shipped to the leader.
- `CommitProcessor.needCommit()` at `CommitProcessor.java:131-148` also has **no `case OpCode.createExt`**, so it falls to `default → false` and the request is not held for a commit.
- `CommitProcessor$CommitWorkRequest.cleanup()` at `CommitProcessor.java:283-290` takes the `if (!stopped)` branch on the resulting NPE and calls `halt()`, permanently disabling request processing on this follower.

## Fix

Add `case OpCode.createExt:` alongside `case OpCode.create:` in both switches: `FollowerRequestProcessor.java:84` (so the follower forwards the write to the leader) and `CommitProcessor.needCommit()` at `CommitProcessor.java:133` (so the follower waits for the resulting COMMIT before running `FinalRequestProcessor`). With those two cases present, the leader's `PrepRequestProcessor.pRequest2Txn` (line 366) will set the `TxnHeader`, the COMMIT-side path will populate `request.hdr`, and `ZKDatabase.addCommittedProposal:251` will no longer NPE.
