## Root cause

`OpCode.createExt` is treated as a quorum operation by `Request.isQuorum()` but is **not listed in `StagedRequestProcessor.needCommit()`**, so a `createExt` request is sent through the terminal processor without ever going through the leader-commit path. When the terminal processor then tries to record it as a committed proposal, it dereferences the still-null `request.hdr`, throws NPE, and the executor-pool's exception handler halts the entire request processor on that peer. All in-flight client sessions on that peer stop receiving anything (including pings), so the client's read-timeout fires with the observed "Session inactive – no server traffic" message and every outstanding call fails `ConnectionLoss`.

Evidence in `logs/symptom.log`:

- L910170/L910671 – ingress of the offending request on `myid:1`:
  `type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/svc4/item-9137` (note the sentinel zxid `0xfffffffffffffffe` — it has not been committed yet).
- L911172-L911180 – the NPE thrown from the same StageWorkThread:
  `java.lang.NullPointerException at ZKStateStore.addCommittedProposal(ZKStateStore.java:251) at TerminalRequestProcessor.processRequest(TerminalRequestProcessor.java:127) at StagedRequestProcessor$StageWorkRequest.doWork(StagedRequestProcessor.java:294) at TaskExecutorPool$ScheduledWorkRequest.run(TaskExecutorPool.java:161)`.
- L911681 – `Downstream stage failed; cannot continue.` from `StagedRequestProcessor$StageWorkRequest@286`.
- L912182 – `StagedRequestProcessor loop terminated`.

That is 18:49:25 on `myid:1`. Port `24551` is `myid:1`'s client port (L16058 `binding to port 0.0.0.0/0.0.0.0:24551`). Session `0x1a008cd5e440000` is a client on `/127.0.0.1:40846` served by `myid:1` (L88263, L92271). From 18:53:56 onward that same session repeatedly logs the client-side timeout in `ClientCnxn.java` (log line matches `ClientCnxn$SendThread@1207`) — i.e. it stops seeing traffic *after* `myid:1`'s pipeline is halted.

## The exact branches that produce it

1. **`needCommit` mis-classification** – `StagedRequestProcessor.needCommit(Request)` at `source/src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java:131-148`:
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
           return false;         // <-- createExt falls here (line 145-146)
   }
   ```
   Meanwhile `Request.isQuorum()` at `source/src/java/main/org/apache/zookeeper/server/Request.java:161-185` explicitly returns **true** for `OpCode.createExt` at line 170. That mismatch is the seed of the bug.

2. **Ingress dispatches immediately, without commit** – `StagedRequestProcessor.run()` at `source/src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java:169-177`:
   ```java
   while (!stopped && !isWaitingForCommit() && !isProcessingCommit()
          && (request = queuedRequests.poll()) != null) {
       if (needCommit(request)) {
           nextPending.set(request);        // would wait for leader commit → hdr/txn filled in
       } else {
           sendToNextProcessor(request);    // <-- createExt takes THIS branch, request.hdr is still null
       }
   }
   ```

3. **Terminal processor blindly records it as a proposal** – `TerminalRequestProcessor.processRequest()` at `source/src/java/main/org/apache/zookeeper/server/TerminalRequestProcessor.java:126-128`:
   ```java
   if (request.isQuorum()) {                                  // true for createExt
       zks.getZKStateStore().addCommittedProposal(request);   // line 127
   }
   ```
   The gating condition disagrees with the gating condition in step 1.

4. **NPE inside `addCommittedProposal`** – `source/src/java/main/org/apache/zookeeper/server/ZKStateStore.java:251`:
   ```java
   request.getHdr().serialize(boa, "hdr");   // getHdr() == null → NPE
   ```

5. **Executor-pool catch-all fires cleanup()** – `TaskExecutorPool$ScheduledWorkRequest.run()` at `source/src/java/main/org/apache/zookeeper/server/TaskExecutorPool.java:154-166`:
   ```java
   } catch (Exception e) {
       LOG.warn("Unexpected exception", e);   // line 163  → the log at 18:49:25,284
       workRequest.cleanup();                 // line 164
   }
   ```

6. **`cleanup()` halts the processor** – `StagedRequestProcessor$StageWorkRequest.cleanup()` at `source/src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java:284-290`:
   ```java
   public void cleanup() {
       if (!stopped) {                        // true here → branch taken
           LOG.error("Downstream stage failed; cannot continue.");  // line 286
           StagedRequestProcessor.this.halt();                      // line 288
       }
   }
   ```
   `halt()` at lines 346-353 sets `stopped = true`, wakes the main loop (which then exits at line 191, "StagedRequestProcessor loop terminated"), clears `queuedRequests`, and stops the `TaskExecutorPool`. Crucially, `processRequest()` at line 333-344 begins with `if (stopped) return;`, so from this point onward **every** incoming request on this peer — including pings and commits fed by the leader — is silently dropped.

7. **Client-side symptom** – with no responses (including pings) coming back, `ClientCnxn$SendThread.run()` at `source/src/java/main/org/apache/zookeeper/ClientCnxn.java:1150-1160` computes `to = readTimeout − clientCnxnSocket.getIdleRecv();` and takes the branch `if (to <= 0)`:
   ```java
   throw new SessionTimeoutException(
       "Session inactive - no server traffic for "
       + clientCnxnSocket.getIdleRecv() + "ms for sessionid 0x"
       + Long.toHexString(sessionId));
   ```
   That exception is caught by the outer loop, the socket is closed, pending packets are surfaced as `ConnectionLoss`, and reconnect attempts to the same broken peer keep hitting the same 6666 ms timeout — exactly the pattern the log shows every ~5-6 minutes for session `0x1a008cd5e440000`.

## Fix

Add `case OpCode.createExt: return true;` to `StagedRequestProcessor.needCommit()` (StagedRequestProcessor.java:131-148) so `createExt` is held in `nextPending` until the leader commits it, giving the request its `hdr`/`txn` before `TerminalRequestProcessor` reaches `addCommittedProposal`. The bug is a missing case, not anything in `ZKStateStore` or `TaskExecutorPool`; those merely faithfully propagate the resulting NPE into a full-processor halt.
