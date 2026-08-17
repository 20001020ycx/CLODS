## Root cause

The client's `Session inactive – no server traffic for 6666ms` message is a *symptom*. The client (`ClientCnxn.SendThread.run`, `ClientCnxn.java:1155-1160`) is doing exactly what it's supposed to do: `to = readTimeout - clientCnxnSocket.getIdleRecv();` goes non‑positive, so it throws `SessionTimeoutException`, gets caught at line 1206–1207, `cleanup()` runs at line 1221, the socket is torn down, and the reconnect path ultimately surfaces `ConnectionLoss` for every in‑flight call. Nothing is broken on the client. The server has simply stopped answering – even pings.

The reason the server stopped answering is a self‑inflicted shutdown of the follower's request pipeline, triggered by a classification mismatch between two operator tables for `OpCode.createExt`.

### The exact failure path (starting from the log evidence)

At `2026-08-14 18:49:25,284` on `myid:1`, `StageWorkThread-2` was processing a client request:

```
Handling submission:: sessionid:0x1a008cd5e440001 type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/svc4/item-9137
…
WARN  [StageWorkThread-2:TaskExecutorPool$ScheduledWorkRequest@163] - Unexpected exception
java.lang.NullPointerException
    at org.apache.zookeeper.server.ZKStateStore.addCommittedProposal(ZKStateStore.java:251)
    at org.apache.zookeeper.server.TerminalRequestProcessor.processRequest(TerminalRequestProcessor.java:127)
    at org.apache.zookeeper.server.quorum.StagedRequestProcessor$StageWorkRequest.doWork(StagedRequestProcessor.java:294)
    at org.apache.zookeeper.server.TaskExecutorPool$ScheduledWorkRequest.run(TaskExecutorPool.java:161)
ERROR [StageWorkThread-2:StagedRequestProcessor$StageWorkRequest@286] - Downstream stage failed; cannot continue.
```

The `zxid:0xfffffffffffffffe` (‑2) and `txntype:unknown` prove this request never went through the leader‑commit path – i.e. `request.getHdr()` is still `null` when Terminal saw it.

### The offending branches

1. **`StagedRequestProcessor.needCommit()` – `source/src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java:131–148`.** The `switch` lists `create`, `delete`, `setData`, `reconfig`, `multi`, `setACL`, `sync` (matchSyncs), `createSession`/`closeSession` (non‑local). **`OpCode.createExt` is not in the switch**, so it hits `default: return false;` at line 146. The main run loop therefore takes the *non‑commit* branch at `StagedRequestProcessor.java:172–176`:
   ```java
   if (needCommit(request)) {
       nextPending.set(request);      // NOT taken for createExt
   } else {
       sendToNextProcessor(request);  // taken → dispatched immediately
   }
   ```
   No commit is ever awaited from the leader, so `request.hdr`/`request.txn` are never populated (they would normally be set in `processCommitted()` at lines 226–228).

2. **`TerminalRequestProcessor.processRequest()` – `source/src/java/main/org/apache/zookeeper/server/TerminalRequestProcessor.java:126–128`.** After `zks.processTxn(request)`, it does:
   ```java
   if (request.isQuorum()) {
       zks.getZKStateStore().addCommittedProposal(request);
   }
   ```
   `Request.isQuorum()` (`Request.java:161–185`) **does include `OpCode.createExt`** (line 170) and returns `true`. So the code enters the branch and calls `addCommittedProposal(request)` with a still‑headerless request.

3. **`ZKStateStore.addCommittedProposal()` – line 251:**
   ```java
   request.getHdr().serialize(boa, "hdr");
   ```
   `getHdr()` is `null` → `NullPointerException`. This is the mismatch: `needCommit` says "not a write, skip commit"; `isQuorum` says "yes, log it to the committed‑proposal cache". The two must agree on `createExt`, and they don't.

4. **The NPE escapes `StageWorkRequest.doWork()` – `StagedRequestProcessor.java:292–313`** (the `finally` decrements counters but rethrows the exception), and is caught in **`TaskExecutorPool.ScheduledWorkRequest.run()` at `TaskExecutorPool.java:162–165`**:
   ```java
   } catch (Exception e) {
       LOG.warn("Unexpected exception", e);
       workRequest.cleanup();
   }
   ```
   `workRequest` is the outer `StageWorkRequest`, whose `cleanup()` (`StagedRequestProcessor.java:283–290`) does:
   ```java
   public void cleanup() {
       if (!stopped) {                                  // line 285 branch → true
           LOG.error("Downstream stage failed; cannot continue.");
           StagedRequestProcessor.this.halt();          // line 288
       }
   }
   ```
   That log line is exactly the second ERROR seen at 18:49:25,325.

5. **`StagedRequestProcessor.halt()` – lines 346–353** flips `stopped = true` and calls `workerPool.stop()`, which shuts down every executor in `TaskExecutorPool.stop()` (`TaskExecutorPool.java:219–226`). The processor's `run()` loop (line 107 `while (state.isAlive())` in the code above is client‑side; here `while (!stopped)` at StagedRequestProcessor.java:154) then exits and logs `"StagedRequestProcessor loop terminated"`.

6. **Silent black‑hole.** After the halt, every subsequent client submission funnelled through
   - `StagedRequestProcessor.processRequest()` at **line 333–344** hits its guard `if (stopped) { return; }` (line 334) and is dropped without enqueue;
   - and every leader COMMIT arriving via `StagedRequestProcessor.commit()` at **line 320–331** hits its guard `if (stopped || request == null) return;` (line 321) and is dropped as well.
   
   The follower keeps accepting TCP sockets and reading bytes (NIO threads are unaffected), so from a network perspective the client is still connected. But no request – not even the ping – ever reaches Terminal or produces a `sendResponse`.

7. **Back on the client.** With no bytes flowing back, `ClientCnxn.SendThread.run()` computes `to = readTimeout - clientCnxnSocket.getIdleRecv();` at `ClientCnxn.java:1150`, and once `to <= 0` (line 1155) it throws
   ```java
   throw new SessionTimeoutException(
           "Session inactive - no server traffic for " + … + " for sessionid 0x" + …);
   ```
   (lines 1156–1160). `readTimeout` = `2·sessionTimeout/3` = `2·10000/3` = **6666 ms**, which matches the log exactly. The `catch` at line 1193, `else‑if` at line 1206 (`e instanceof SessionTimeoutException`) prints the "closing socket connection and attempting reconnect" message (line 1207), then `cleanup()` at line 1221 converts every pending/outgoing packet to `ConnectionLoss` via `conLossPacket()` (StagedRequestProcessor is unrelated here; the client's `cleanup()` at ClientCnxn line 1295–1309 drains `pendingQueue`/`outgoingQueue`). Once the session's actual timeout elapses the server marks it expired, and further operations issued by the application fail with `KeeperException.ConnectionLoss`.

### One-line summary

`StagedRequestProcessor.needCommit()` at `src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java:131–148` is missing a `case OpCode.createExt:` (or the mirror bug: `Request.isQuorum()` at `Request.java:170` shouldn't include `createExt` unless `needCommit` does). The two classifiers disagree, so a `createExt` reaches `TerminalRequestProcessor.processRequest` (`TerminalRequestProcessor.java:126–127`) with a null header, `ZKStateStore.addCommittedProposal` NPEs at line 251, the exception is caught in `TaskExecutorPool.ScheduledWorkRequest.run` (line 162‑165) which calls `StageWorkRequest.cleanup` (`StagedRequestProcessor.java:285`) → `halt()` (line 288 → 346) → `stopped = true` and `workerPool.stop()`. From that moment the guards `if (stopped) return;` in `processRequest` (line 334) and `commit` (line 321) drop every submission and every commit on the floor, so no server traffic ever comes back on the client's socket, and `ClientCnxn.SendThread.run` fires the `to <= 0` branch at `ClientCnxn.java:1155` after `2·sessionTimeout/3 = 6666 ms`, throws `SessionTimeoutException`, and the reconnect loop surfaces `ConnectionLoss` for all pending calls.
