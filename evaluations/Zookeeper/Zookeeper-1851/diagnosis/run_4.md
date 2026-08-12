## Root cause

The `create(..., Stat)` overload uses a *new* opcode, `OpCode.createExt`, that was added to some request‑routing tables but omitted from the two switches on the follower's write path. The follower therefore short‑circuits the request into `FinalRequestProcessor` with **no committed txn header**, and the ensuing NPE trips the CommitProcessor's fatal‑exception cleanup, permanently killing every session on that follower.

### The exact code path (with branches)

1. **Client side — the new op is emitted.**
   `ZooKeeper.create(path, data, acl, createMode, Stat)` sets the opcode explicitly:
   - `src/java/main/org/apache/zookeeper/ZooKeeper.java:1143` → `h.setType(ZooDefs.OpCode.createExt);`
   The 4‑arg overload above uses `OpCode.create`, which is why the earlier call succeeded.

2. **Follower fails to forward `createExt` to the leader.**
   `FollowerRequestProcessor.run()` switch has no `case OpCode.createExt`, so the fall‑through branch never calls `zks.getFollower().request(request)`:
   - `src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79‑100`
     (compare: `OpCode.create` at line 84 *is* listed; `createExt` is not.)
   The request is still queued into the next processor because `nextProcessor.processRequest(request)` was called before the switch (line 72).

3. **CommitProcessor treats `createExt` as a read.**
   `CommitProcessor.needCommit()` switch again has no `case OpCode.createExt`, so it hits `default: return false`:
   - `src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131‑148`
   Consequently `run()` takes the else branch at line 172‑176 and calls `sendToNextProcessor(request)` **without ever setting `nextPending`** — the follower doesn't wait for a commit that will never come.

4. **`FinalRequestProcessor` enters the quorum bookkeeping branch on an uncommitted request.**
   Because `Request.isQuorum()` *does* list `createExt`:
   - `src/java/main/org/apache/zookeeper/server/Request.java:170` → `case OpCode.createExt: … return true;`
   the branch at `FinalRequestProcessor.java:126` is taken:
   ```java
   if (request.isQuorum()) {
       zks.getZKDatabase().addCommittedProposal(request);   // line 127
   }
   ```
   But since step 2 never sent the request to the leader, `request.getHdr()` is still `null`.

5. **NPE inside `addCommittedProposal`.**
   `src/java/main/org/apache/zookeeper/server/ZKDatabase.java:251`:
   ```java
   request.getHdr().serialize(boa, "hdr");   // getHdr() == null → NPE
   ```
   The stack trace in the log confirms exactly this line:
   ```
   java.lang.NullPointerException
       at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
       at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
       at CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
       at WorkerService$ScheduledWorkRequest.run(WorkerService.java:161)
   ```
   The surrounding try/catch in `FinalRequestProcessor` (lines 154‑454) only wraps the response‑building switch; `addCommittedProposal` is called *before* it, so the NPE escapes.

6. **The escape triggers `CommitProcessor.halt()` — the follower becomes a black hole.**
   `WorkerService.ScheduledWorkRequest.run()` catches every `Exception` and calls `workRequest.cleanup()`:
   - `src/java/main/org/apache/zookeeper/server/WorkerService.java:161‑165`
   Which lands in the fatal branch of `CommitProcessor.CommitWorkRequest.cleanup()`:
   - `src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:283‑290`
     ```java
     if (!stopped) {
         LOG.error("Exception thrown by downstream processor, unable to continue.");
         CommitProcessor.this.halt();
     }
     ```
   `halt()` at lines 346‑353 sets `stopped = true`, clears `queuedRequests`, and stops the worker pool. From then on:
   - `CommitProcessor.processRequest()` early‑returns on every incoming request via `if (stopped) return;` (line 333‑335).
   - `CommitProcessor.run()` exits (the log's `"CommitProcessor exited loop!"` immediately after the NPE).
   The follower still accepts TCP connections and its `FollowerRequestProcessor` still enqueues, but nothing downstream ever runs — every client, on every session, times out with `ConnectionLoss`, reconnects, and times out again.

### Why the plain `create` 8 ms earlier succeeded
Plain `create` uses `OpCode.create`, which **is** listed in both `FollowerRequestProcessor.run()` (line 84) and `CommitProcessor.needCommit()` (line 133). It was forwarded to the leader, committed, and processed normally. Only `createExt` skips those two switches, producing the header‑less request that blows up in `addCommittedProposal`.

### The fix
Add `case OpCode.createExt:` to both switches — `FollowerRequestProcessor.run()` (with the other write ops at ZooKeeper/server/quorum/FollowerRequestProcessor.java:84‑92) and `CommitProcessor.needCommit()` (ZooKeeper/server/quorum/CommitProcessor.java:133‑139) — so the request is forwarded to the leader and the follower waits for the commit before invoking `FinalRequestProcessor`. (Independently, `FinalRequestProcessor.java:126‑128` should be robust to a null `hdr`, and `CommitProcessor.CommitWorkRequest.cleanup` arguably shouldn't kill the whole processor over a single request's exception — but the primary defect is the two missing switch cases.)
