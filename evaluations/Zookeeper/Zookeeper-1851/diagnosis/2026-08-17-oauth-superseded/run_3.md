## Root cause

The follower's `StagedRequestProcessor` on server `myid:1` dies on an unhandled `NullPointerException`, and its own error-handling then permanently silences the entire request pipeline for that server. Clients homed on that server (session-ids beginning `0x1a…`) stop receiving *any* traffic — including pings — so `ClientCnxn.SendThread` trips its read-timeout, throws `SessionTimeoutException("Session inactive …")`, tears the socket down and surfaces `ConnectionLoss`.

The log line that unlocks it is:

```
2026-08-14 18:49:25,284 [myid:1] - WARN  [StageWorkThread-2:TaskExecutorPool$ScheduledWorkRequest@163] - Unexpected exception
java.lang.NullPointerException
    at org.apache.zookeeper.server.ZKStateStore.addCommittedProposal(ZKStateStore.java:251)
    at org.apache.zookeeper.server.TerminalRequestProcessor.processRequest(TerminalRequestProcessor.java:127)
    at org.apache.zookeeper.server.quorum.StagedRequestProcessor$StageWorkRequest.doWork(StagedRequestProcessor.java:294)
    at org.apache.zookeeper.server.TaskExecutorPool$ScheduledWorkRequest.run(TaskExecutorPool.java:161)
...
2026-08-14 18:49:25,325 [myid:1] - ERROR [StageWorkThread-2:StagedRequestProcessor$StageWorkRequest@286] - Downstream stage failed; cannot continue.
2026-08-14 18:49:25,325 [myid:1] - INFO  [StagedRequestProcessor:1:StagedRequestProcessor@191] - StagedRequestProcessor loop terminated
```

### The failure path, branch by branch

1. **Un-guarded serialization of a null header.** `TerminalRequestProcessor.processRequest` (source/src/java/main/org/apache/zookeeper/server/TerminalRequestProcessor.java) only checks `request.getHdr() != null` for the `outstandingChanges` bookkeeping at line 108, then unconditionally does

   ```java
   // lines 125-128
   if (request.isQuorum()) {
       zks.getZKStateStore().addCommittedProposal(request);
   }
   ```

   `Request.isQuorum()` (Request.java:161-185) returns `true` for `create/delete/setData/setACL/check/multi/reconfig` and for non-local `createSession/closeSession` **irrespective of whether a TxnHeader was ever attached**. When such a request arrives with `hdr == null` (e.g. a non-local `closeSession` that the leader committed without a preceding `PrepRequestProcessor` on this follower populating hdr/txn), `addCommittedProposal` blows up at:

   ```java
   // ZKStateStore.java:251
   request.getHdr().serialize(boa, "hdr");   // NPE — getHdr() is null
   ```

   The `if (request.getHdr() != null)` guard at TerminalRequestProcessor.java:108 covers the outstandingChanges bookkeeping but not this second use of `hdr`.

2. **The NPE escapes the worker.** `StagedRequestProcessor$StageWorkRequest.doWork` (StagedRequestProcessor.java:292-313) runs `nextProcessor.processRequest(request)` (line 294). Its `finally` clears `currentlyCommitting` and decrements `numRequestsProcessing`, but re-throws the NPE. The wrapping `TaskExecutorPool$ScheduledWorkRequest.run` catches it (TaskExecutorPool.java:162-165):

   ```java
   } catch (Exception e) {
       LOG.warn("Unexpected exception", e);   // <-- line 163, seen in log
       workRequest.cleanup();                 // <-- line 164
   }
   ```

3. **`cleanup()` fires `halt()` for the whole processor.** (StagedRequestProcessor.java:283-290)

   ```java
   public void cleanup() {
       if (!stopped) {                         // branch taken: stopped == false
           LOG.error("Downstream stage failed; cannot continue.");   // <-- seen in log
           StagedRequestProcessor.this.halt();
       }
   }
   ```

   `halt()` at lines 346-353 sets `stopped = true`, wakes the run loop, clears `queuedRequests`, and shuts the worker pool down.

4. **Main loop terminates.** In `run()` (line 154) the `while (!stopped)` condition becomes false, control falls out of the loop and logs at line 191: `"StagedRequestProcessor loop terminated"` — exactly what appears in the log.

5. **All subsequent client traffic on this server is silently dropped.** After `stopped == true`:

   ```java
   // StagedRequestProcessor.java:333-336
   public void processRequest(Request request) {
       if (stopped) { return; }        // <— silently drops every new client request
       ...
   }
   // StagedRequestProcessor.java:320-323
   public void commit(Request request) {
       if (stopped || request == null) { return; }   // <— silently drops leader commits
       ...
   }
   ```

   Nothing ever calls `sendToNextProcessor` again, so `TerminalRequestProcessor` is never invoked and **`cnxn.sendResponse(...)` is never reached for any request — including pings**. The server accepts the TCP connection and reads bytes, but the client sees zero response bytes.

6. **Client-side timeout fires (the exact log line in the ticket).** In `ClientCnxn$SendThread.run` (source/src/java/main/org/apache/zookeeper/ClientCnxn.java):

   ```java
   // lines 1150-1161
   if (state.isConnected()) {
       to = readTimeout - clientCnxnSocket.getIdleRecv();
   } else {
       to = connectTimeout - clientCnxnSocket.getIdleRecv();
   }

   if (to <= 0) {                                         // taken: no server bytes for ~2/3 of session timeout
       throw new SessionTimeoutException(
               "Session inactive - no server traffic for "
                       + clientCnxnSocket.getIdleRecv() + "ms"
                       + " for sessionid 0x"
                       + Long.toHexString(sessionId));
   }
   ```

   The throw is caught a few lines below at ClientCnxn.java:1206-1207:

   ```java
   } else if (e instanceof SessionTimeoutException) {
       LOG.info(e.getMessage() + RETRY_CONN_MSG);   // "…closing socket connection and attempting reconnect"
   }
   ```

   → `cleanup()` closes the socket, `Disconnected` is queued to the event thread, in-flight packets in `pendingQueue`/`outgoingQueue` complete with `KeeperException.ConnectionLoss`, and the client attempts to reconnect. If it happens to reconnect back to the dead server it re-enters the same silent-drop state; otherwise it may briefly succeed until a subsequent NPE-triggered halt hits another peer.

### The two-line summary of the defect

- **Trigger (data bug):** `TerminalRequestProcessor.java:127` calls `addCommittedProposal(request)` on any `request.isQuorum()`, but `ZKStateStore.addCommittedProposal:251` dereferences `request.getHdr()` without a null-check — so a committed non-local `closeSession`/`createSession` (whose `isQuorum()` is true by the `!isLocalSession` branch in `Request.java:179-181`) with no hdr immediately NPEs.
- **Fatal amplifier (control-flow bug):** `StagedRequestProcessor$StageWorkRequest.cleanup()` (StagedRequestProcessor.java:283-290) treats *any* downstream exception as unrecoverable and invokes `halt()` (line 346-353), which flips the process-wide `stopped` flag. From then on `processRequest()`/`commit()` (lines 333-336, 320-323) return immediately without producing responses or pings, so every client session hosted on that peer eventually hits the `to <= 0` branch at `ClientCnxn.java:1155` and dies with `Session inactive … ConnectionLoss` — precisely the symptom reported.
