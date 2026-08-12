## Root cause

`CommitProcessor.needCommit()` is missing the `OpCode.createExt` case. On a follower, this bug causes an extended‑create (TTL/container node) request to bypass the "wait for the leader's COMMIT" state, get scheduled straight to `FinalRequestProcessor` while its `TxnHeader` is still null, then hit a `NullPointerException` inside `ZKDatabase.addCommittedProposal`. The NPE bubbles up to `WorkerService`, which invokes `CommitWorkRequest.cleanup()`; because `stopped == false`, cleanup calls `CommitProcessor.halt()` and the follower's request pipeline is permanently shut down. All subsequent client traffic on that follower (writes, watches, pings) goes unanswered, and after ~6.6 s (2/3 of the 10 000 ms negotiated session timeout) each client's `SendThread` in `ClientCnxn` gives up the socket with the "Client session timed out, have not heard from server in 6670 ms" log line, surfacing as `KeeperException.ConnectionLoss` to the caller.

## Evidence in `logs/symptom.log`

- Line 1873 `type:createExt cxid:0x4 zxid:0xfffffffffffffffe … reqpath:/app/failing/with-stat` — the follower queues the createExt via `CommitProcessor@338` (`processRequest`).
- Line 1874 `FinalRequestProcessor@91` picks up the SAME createExt still with `zxid:0xfffffffffffffffe txntype:unknown` — proof that it never waited for the leader COMMIT (a committed write would show a real zxid such as `0x1000002cX` and `txntype:1`, as every other create above it does).
- Lines 1875–1883 stack trace:
  ```
  java.lang.NullPointerException
      at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
      at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
      at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
      at org.apache.zookeeper.server.WorkerService$ScheduledWorkRequest.run(WorkerService.java:161)
  ```
- Line 1884 `CommitProcessor$CommitWorkRequest@286` — `"Exception thrown by downstream processor, unable to continue."`
- Line 1885 `CommitProcessor@191` — `"CommitProcessor exited loop!"`
- Lines 1886/1889 — 6.6 s later, both client sockets on this follower close after their `SendThread` timeouts (0x19ff…0000 and 0x19ff…0001), which is exactly the timeout in the symptom message.

## Exact code path and branches taken

1. **`CommitProcessor.needCommit()` — `src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131‑148`**
   ```java
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
   ```
   `OpCode.createExt` is not listed, so control falls through to `default: return false`. `createExt` is a mutating op (it is listed in `Request.isQuorum()` at line 170 as `return true`, and in `Request.isValid()` at line 138, and it is what `ZooKeeper.create(..., ttl/container, ...)` submits). It must go through the two‑phase commit path like `create`, but here it doesn't.

2. **`CommitProcessor.run()` inner loop — `CommitProcessor.java:169‑177`**
   ```java
   while (!stopped && !isWaitingForCommit() && !isProcessingCommit() &&
          (request = queuedRequests.poll()) != null) {
       if (needCommit(request)) {          // false for createExt
           nextPending.set(request);       // NOT taken
       } else {
           sendToNextProcessor(request);   // TAKEN — schedules FinalRequestProcessor immediately
       }
   }
   ```
   Because `needCommit()` returned false, the `else` branch fires and the createExt is handed to a `CommitWorkRequest` on the worker pool before the leader's `Leader.COMMIT` packet has installed the `TxnHeader` on the pending `Request`. `request.getHdr()` is still `null`, `request.zxid` is still the sentinel `0xfffffffffffffffe` (`ZooDefs.OpCode`‑style sentinel visible in the log).

3. **`FinalRequestProcessor.processRequest()` — `src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:126‑128`**
   ```java
   if (request.isQuorum()) {            // TRUE — Request.java:170 returns true for createExt
       zks.getZKDatabase().addCommittedProposal(request);   // line 127
   }
   ```
   `request.isQuorum()` at `Request.java:161‑185` hits `case OpCode.createExt: … return true` (line 170), so the guarded branch is taken.

4. **`ZKDatabase.addCommittedProposal()` — `src/java/main/org/apache/zookeeper/server/ZKDatabase.java:251`**
   ```java
   request.getHdr().serialize(boa, "hdr");   // NPE — getHdr() is null
   ```
   The header is normally set by `CommitProcessor.processCommitted()` (`CommitProcessor.java:226‑228`: `pending.setHdr(request.getHdr()); pending.setTxn(request.getTxn()); pending.zxid = request.zxid;`) when the leader's COMMIT lands, matched against `nextPending`. That never happened, because step 1 skipped `nextPending.set(request)`. Result: `NullPointerException`.

5. **`CommitProcessor$CommitWorkRequest.doWork` / `cleanup` — `CommitProcessor.java:284‑290`**
   The NPE is not caught in `doWork()`; it propagates to `WorkerService$ScheduledWorkRequest` (line 163 in the log), which invokes `cleanup()`:
   ```java
   public void cleanup() {
       if (!stopped) {                                    // TRUE — first failure
           LOG.error("Exception thrown by downstream processor, unable to continue.");
           CommitProcessor.this.halt();
       }
   }
   ```
   The `!stopped` branch is taken (this is the first failure), so `halt()` runs.

6. **`CommitProcessor.halt()` — `CommitProcessor.java:346‑353`**
   ```java
   stopped = true;
   wakeup();
   queuedRequests.clear();
   if (workerPool != null) { workerPool.stop(); }
   ```
   Sets `stopped=true`. The `run()` loop's outer `while (!stopped)` (line 154) evaluates to false on next iteration, so it exits and logs `"CommitProcessor exited loop!"` at line 191 (matches the log line at 01:41:52,264).

7. **Downstream effect on the client (source of the symptom log line).** With `CommitProcessor` down and `queuedRequests` cleared, the follower's request pipeline is severed: `FollowerRequestProcessor` will still call `CommitProcessor.processRequest`, but at line 333 the guard
   ```java
   public void processRequest(Request request) {
       if (stopped) { return; }        // TAKEN
       ...
   }
   ```
   discards every subsequent request. The follower keeps its TCP socket open, but sends no replies (no write results, no ping responses). Ping responses drive `lastHeard` in `ClientCnxn.SendThread.readTimeout`; once `now - lastHeard > readTimeout` (with `readTimeout = 2 * negotiatedTimeout / 3`; negotiated 10 000 ms in the log → 6 666 ms threshold, matching the observed "6670 ms"), the send thread at `ClientCnxn.java:1207` logs the "Client session timed out, have not heard from server in 6670ms" message from the symptom, tears down the socket, and enters reconnect. Each reconnect attempt against this follower behaves the same way, so the queue in `outgoingQueue` drains as `ConnectionLossException`, which is surfaced to the caller as `KeeperException.ConnectionLoss`.

## Fix

Add `case OpCode.createExt:` alongside `case OpCode.create:` (and the other mutators) in `CommitProcessor.needCommit()` at `CommitProcessor.java:131‑148`, so that createExt takes the `nextPending.set(request)` branch and is only handed downstream after the leader's COMMIT has populated the header via `processCommitted()`.
