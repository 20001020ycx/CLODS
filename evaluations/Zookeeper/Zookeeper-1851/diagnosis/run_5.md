## Root Cause

`OpCode.createExt` was omitted from `StagedRequestProcessor.needCommit()`. A `createExt` request is a write, but the switch treats it as a read, dispatches it straight to the terminal processor without a committed txn header, and later blows up on `request.getHdr().serialize(...)`. The resulting NPE tears down the whole request pipeline on that server; every subsequent client call (including pings) is silently dropped, so the client eventually trips its own idle‑read timeout and reports `ConnectionLoss`.

## Evidence in the log

- The affected client (session `0x1a008cd5e440000`) is talking to `127.0.0.1:24551`, which is the client port of `myid=1` (`symptom.log:16058` — `binding to port 0.0.0.0/0.0.0.0:24551` under `[myid:1]`).
- At `2026-08-14 18:49:25,284` on `myid=1`, `StageWorkThread-2` processes exactly one request:
  `type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/svc4/item-9137` — note **zxid = -2 and txntype = unknown**, meaning this request never went through the leader commit path.
- Immediately after, the thread throws:
  ```
  java.lang.NullPointerException
    at org.apache.zookeeper.server.ZKStateStore.addCommittedProposal(ZKStateStore.java:251)
    at org.apache.zookeeper.server.TerminalRequestProcessor.processRequest(TerminalRequestProcessor.java:127)
    at org.apache.zookeeper.server.quorum.StagedRequestProcessor$StageWorkRequest.doWork(StagedRequestProcessor.java:294)
    at org.apache.zookeeper.server.TaskExecutorPool$ScheduledWorkRequest.run(TaskExecutorPool.java:161)
  ```
- That is followed by `ERROR ... StagedRequestProcessor$StageWorkRequest@286 - Downstream stage failed; cannot continue.` and `INFO ... StagedRequestProcessor@191 - StagedRequestProcessor loop terminated`. Both messages occur exactly once in the whole log, only on `myid=1`. After that timestamp, the client for `0x1a008cd5e440000` never gets another byte from `127.0.0.1:24551` and begins its 6.6 s idle‑timeout reconnect loop that appears in the symptom.

## The exact branches that produce the failure

1. `source/src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java:131-148` — `needCommit(Request)`:

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
   `OpCode.createExt` is missing, so for a `createExt` this method falls into `default` and returns **false**.

2. `StagedRequestProcessor.run()` at `source/.../StagedRequestProcessor.java:169-177` — because `needCommit(request)` is false, this branch is taken:
   ```java
   if (needCommit(request)) {
       nextPending.set(request);
   } else {
       sendToNextProcessor(request);   // <-- taken for createExt
   }
   ```
   The uncommitted write is scheduled to a worker thread (line 175 → `sendToNextProcessor` at line 267 → `workerPool.schedule(new StageWorkRequest(request), request.sessionId)`), so it reaches `TerminalRequestProcessor` **with `request.hdr == null` and `request.zxid == -2`**.

3. `source/src/java/main/org/apache/zookeeper/server/Request.java:161-185` — `isQuorum()` for `OpCode.createExt` returns **true** (`case OpCode.createExt: ... return true;`).

4. `source/src/java/main/org/apache/zookeeper/server/TerminalRequestProcessor.java:126-128`:
   ```java
   if (request.isQuorum()) {                        // true for createExt
       zks.getZKStateStore().addCommittedProposal(request);   // called with hdr == null
   }
   ```

5. `source/src/java/main/org/apache/zookeeper/server/ZKStateStore.java:251`:
   ```java
   request.getHdr().serialize(boa, "hdr");   // NPE: getHdr() == null
   ```
   This is the exact frame in the stack trace.

6. The exception propagates out of `StageWorkRequest.doWork()` (`StagedRequestProcessor.java:292-313`) and is caught in `TaskExecutorPool$ScheduledWorkRequest.run` (`TaskExecutorPool.java:161-165`), which calls `workRequest.cleanup()`.

7. `StagedRequestProcessor$StageWorkRequest.cleanup()` at `StagedRequestProcessor.java:284-290`:
   ```java
   public void cleanup() {
       if (!stopped) {                                   // branch taken
           LOG.error("Downstream stage failed; cannot continue.");
           StagedRequestProcessor.this.halt();           // <-- kills the processor
       }
   }
   ```

8. `halt()` at `StagedRequestProcessor.java:346-353` sets `stopped = true`, clears `queuedRequests`, and stops `workerPool`. The main run loop exits (log line “StagedRequestProcessor loop terminated”).

9. From that point on, every incoming client request — including pings — is silently dropped by `StagedRequestProcessor.processRequest` at line 333-343:
   ```java
   public void processRequest(Request request) {
       if (stopped) {                       // now true forever
           return;                          // <-- request discarded
       }
       ...
   }
   ```
   Because pings are drained here (only `TerminalRequestProcessor` actually writes the ping response at line 187-189), the server sends nothing back to the client.

10. Client side — `source/src/java/main/org/apache/zookeeper/ClientCnxn.java:1150-1161` in `SendThread.run()`:
    ```java
    to = readTimeout - clientCnxnSocket.getIdleRecv();
    ...
    if (to <= 0) {
        throw new SessionTimeoutException(
                "Session inactive - no server traffic for "
                        + clientCnxnSocket.getIdleRecv() + "ms"
                        + " for sessionid 0x"
                        + Long.toHexString(sessionId));
    }
    ```
    caught at line 1206-1207 (`e instanceof SessionTimeoutException` branch → `LOG.info(e.getMessage() + RETRY_CONN_MSG)`), producing the exact message in the symptom and forcing the socket closed. In‑flight and subsequent user calls return `KeeperException.ConnectionLoss` as the outstanding packets are drained by `cleanup()`.

## Summary

- Precise defect: **`OpCode.createExt` is missing from `StagedRequestProcessor.needCommit()`** (`source/.../quorum/StagedRequestProcessor.java:131-148`). Because `Request.isQuorum()` *does* include `createExt`, the mismatch guarantees an NPE the first time any client issues a `createExt` on that server.
- Trigger path: `needCommit==false → sendToNextProcessor (line 175) → TerminalRequestProcessor line 127 → ZKStateStore.addCommittedProposal line 251 (NPE on null hdr) → StageWorkRequest.cleanup line 286 → StagedRequestProcessor.halt line 346`.
- Effect on clients: after `halt()`, `processRequest`’s `if (stopped) return;` branch at line 334 discards every request (pings included), so `ClientCnxn.SendThread` hits the `to <= 0` branch at line 1155, throws `SessionTimeoutException`, logs the “Session inactive – no server traffic for ~6666 ms …” message from line 1157, and the client’s outstanding operations complete with `ConnectionLoss`.

Fix: add `case OpCode.createExt: return true;` alongside `case OpCode.create:` in `StagedRequestProcessor.needCommit()` so `createExt` writes wait for the leader commit like every other write.
