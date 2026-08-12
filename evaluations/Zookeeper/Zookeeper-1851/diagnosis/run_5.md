## Root cause

The follower's request pipeline crashes with a `NullPointerException` because the new op code **`OpCode.createExt`** is treated as a quorum write by some processors but as a read (no‑commit) op by others. The inconsistency causes a follower to hand an un‑proposed request to `FinalRequestProcessor`, which then NPEs, kills `CommitProcessor`, and freezes every client attached to that follower — the exact ConnectionLoss you see for sessions on `127.0.0.1:24551` (follower `myid=1`).

### The exact chain of code and branches

1. **Client sends `createExt` → follower `FollowerRequestProcessor` does NOT forward it to the leader.**
   `source/src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79‑100` — the switch that forwards write ops to the leader lists `create/delete/setData/reconfig/setACL/multi/check` and `sync`, but **has no `case OpCode.createExt`**. Since none of the switch labels match, `zks.getFollower().request(request)` is never called, and the request never becomes a leader proposal. However, line 72 still calls `nextProcessor.processRequest(request)`, so the request is enqueued locally into `CommitProcessor`.

2. **Follower `CommitProcessor` treats the request as non‑quorum and sends it downstream immediately.**
   `source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131‑148` — `needCommit()` returns `true` for `create/delete/setData/reconfig/multi/setACL` (and conditionally for `sync`/`createSession`/`closeSession`) but **has no `case OpCode.createExt`**, so it falls through to `default: return false`. The main loop at lines 169‑177 therefore skips the `nextPending.set(request)` branch and takes `sendToNextProcessor(request)` at line 175 — the request is dispatched to `FinalRequestProcessor` without waiting for the leader's commit. As a result the `hdr`, `txn`, and `zxid` on the `Request` are never populated (in the log the request still carries the sentinel `zxid:0xfffffffffffffffe txntype:unknown` when it reaches `FinalRequestProcessor@91`, line 1874).

3. **`FinalRequestProcessor` still thinks `createExt` is a quorum op and calls `addCommittedProposal`.**
   `source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:126‑128`:
   ```java
   if (request.isQuorum()) {
       zks.getZKDatabase().addCommittedProposal(request);
   }
   ```
   `Request.isQuorum()` (`source/src/java/main/org/apache/zookeeper/server/Request.java:161‑185`) **does list `case OpCode.createExt: return true`** at line 170, so the branch is taken.

4. **NPE inside `addCommittedProposal`.**
   `source/src/java/main/org/apache/zookeeper/server/ZKDatabase.java:235‑269` — line **251** executes `request.getHdr().serialize(boa, "hdr");`. Because step 2 skipped the leader‑commit path, `request.getHdr()` is `null`, producing the `NullPointerException` at ZKDatabase.java:251 that appears in the log (`java.lang.NullPointerException at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)`).

5. **The NPE permanently halts the follower's `CommitProcessor`.**
   The exception propagates out of `CommitWorkRequest.doWork()` (`CommitProcessor.java:293‑294`). `WorkerService$ScheduledWorkRequest.run` invokes `cleanup()`, which at `CommitProcessor.java:284‑290` takes the `if (!stopped)` branch, logs `"Exception thrown by downstream processor, unable to continue."`, and calls `CommitProcessor.this.halt()`. The main loop at `CommitProcessor.java:151‑192` exits via the `Throwable` catch at line 188 and prints `"CommitProcessor exited loop!"` (matches log line 1885).

6. **Clients on that follower observe `ConnectionLoss`.**
   With the follower's `CommitProcessor` dead, any subsequent client request (writes, and even the pipeline replies) never progress. The client's `SendThread` stops receiving anything from the server; when `ClientCnxn` finds it has been `readTimeout` (= 2/3 × 10 000 ms ≈ 6667 ms) without traffic, it logs the message you quoted (`ClientCnxn$SendThread@1207 "Client session timed out, have not heard from server in 6670ms ... closing socket connection and attempting reconnect"`) and delivers `KeeperException.ConnectionLoss` to the caller. Reconnects to the same server keep re‑establishing sessions but immediately hang again for the same reason, producing the repeating timeout entries at 01:42:07, 01:42:15, 01:42:24, etc.

### The single logical defect

`OpCode.createExt` is included in `Request.isValid()` (Request.java:138), `Request.isQuorum()` (Request.java:170), and `Request.op2String()` (Request.java:193‑194), but is **omitted** from both

- `CommitProcessor.needCommit()` switch at `CommitProcessor.java:131‑147`, and
- `FollowerRequestProcessor.run()` forwarding switch at `FollowerRequestProcessor.java:79‑100`.

That mismatch is the root cause: on a follower, a `createExt` write is neither forwarded to the leader nor held pending a commit, so it reaches `FinalRequestProcessor` with `hdr == null`; combined with `isQuorum()==true` taking the `addCommittedProposal` branch at `FinalRequestProcessor.java:127`, it NPEs at `ZKDatabase.java:251`, halting the follower's `CommitProcessor` and stalling all clients connected to that server — which then time out with `ConnectionLoss`.
