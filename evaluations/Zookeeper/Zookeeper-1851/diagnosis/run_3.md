Based on my analysis, I now have enough understanding to provide a final answer. Let me compile the diagnosis.

## Root Cause Analysis

**Diagnosis:** The 10‑second sessions (0x1a008cd5e440000 and 0x1a008cd5e440001, both connected to follower `myid=1` on 127.0.0.1:24551) are being killed by the client's own `SessionTimeoutException` because their traffic — including keep‑alive pings — is stalled behind pending write commits inside the follower's custom `StagedRequestProcessor`. For clients with a 40 s negotiated timeout (readTimeout ≈ 26.6 s) the same stalls are invisible; only the 10 s clients (readTimeout = 6666 ms = 2/3 × 10000, matching the "6666ms" figure in the log exactly) are short enough to trip the client‑side check.

### The specific code and branches

**1) Client side — where the exception is raised**

`source/src/java/main/org/apache/zookeeper/ClientCnxn.java`, `SendThread.run()`:

```
1150:    to = readTimeout - clientCnxnSocket.getIdleRecv();
...
1155:    if (to <= 0) {
1156:        throw new SessionTimeoutException(
1157:            "Session inactive - no server traffic for "
1158:                + clientCnxnSocket.getIdleRecv() + "ms"
1159:                + " for sessionid 0x"
1160:                + Long.toHexString(sessionId));
1161:    }
```

with `readTimeout = sessionTimeout * 2 / 3` (line 393 and again on session‑complete at 1338). For `sessionTimeout=10000` that is 6666 — exactly the `6666ms` value logged. The exception is then caught at 1206 → `LOG.info(e.getMessage() + RETRY_CONN_MSG)` (line 1207 in the stack you see in the log), `cleanup()` runs, all in‑flight packets are turned into `ConnectionLoss`, and the socket is torn down.

That side is deterministic: any 6666 ms window without a single inbound byte kills the session.

**2) Server side — why no inbound byte arrives for >6666 ms**

`source/src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java`, the run loop the follower uses to gate the pipeline (line 151 onwards):

The wait predicate (lines 156–161):
```
156:    while (
157:        !stopped &&
158:        ((queuedRequests.isEmpty() || isWaitingForCommit() || isProcessingCommit()) &&
159:         (committedRequests.isEmpty() || isProcessingRequest()))) {
160:        wait();
161:    }
```

The queue‑drain loop (lines 169–177):
```
169:    while (!stopped && !isWaitingForCommit() &&
170:           !isProcessingCommit() &&
171:           (request = queuedRequests.poll()) != null) {
172:        if (needCommit(request)) {
173:            nextPending.set(request);      // <-- write blocks the whole processor
174:        } else {
175:            sendToNextProcessor(request);  // reads/pings go to StageWorkThread
176:        }
177:    }
```

The classifier (lines 131–148):
```
131:    protected boolean needCommit(Request request) {
132:        switch (request.type) {
133:            case OpCode.create:
134:            case OpCode.delete:
135:            case OpCode.setData:
136:            case OpCode.reconfig:
137:            case OpCode.multi:
138:            case OpCode.setACL:
139:                return true;
140:            case OpCode.sync:
141:                return matchSyncs;
142:            case OpCode.createSession:
143:            case OpCode.closeSession:
144:                return !request.isLocalSession();
145:            default:
146:                return false;
147:        }
148:    }
```

The failing session's workload (visible in the log at every iteration) is `create /app/svc2/cN` → `getData` → `delete /app/svc2/cN` on an ephemeral node. When the client submits `OpCode.create`, `FollowerIngressProcessor.processRequest` (line 108–131) first calls `zks.checkUpgradeSession(request)` (`QuorumZooKeeperServer` lines 65–83), which — because the node is ephemeral and the caller is a local session — synthesizes an upgrade `Request` (`OpCode.createSession` with `cnxn == null`, `isLocalSession=false`), so `needCommit` returns `true` for both the upgrade **and** the create itself. Both are queued to `StagedRequestProcessor`.

Once the first of these hits line 173, `nextPending` is non‑null and `isWaitingForCommit()` returns true. From that instant, the guard on line 169 (`!isWaitingForCommit() && !isProcessingCommit()`) is false, so the `StagedRequestProcessor` main thread **stops dequeuing anything from `queuedRequests`** — including this session's PINGs and every other client's reads on this follower. Nothing moves forward until the leader commits the upgrade and the follower's worker finishes it (lines 267–314, `sendToNextProcessor` → `TaskExecutorPool.schedule` → `StageWorkRequest.doWork` → the `finally` block that clears `currentlyCommitting` and only then wakes the main thread again).

Two feeder methods make the stall worse by suppressing wakeups exactly when they are needed:

`StagedRequestProcessor.commit` (lines 320–331):
```
327:    committedRequests.add(request);
328:    if (!isProcessingCommit()) {
329:        wakeup();
330:    }
```

`StagedRequestProcessor.processRequest` (lines 333–344):
```
340:    queuedRequests.add(request);
341:    if (!isWaitingForCommit()) {
342:        wakeup();
343:    }
```

Both take the "don't wake up" branch under exactly the conditions where the main thread is parked in `wait()` (the second branch of the composite predicate on line 159 has been satisfied by `committedRequests.isEmpty()` or `queuedRequests.isEmpty()`, and the other branch is the one they suppress). So a ping arriving while `isWaitingForCommit()` is true is silently deposited and never wakes the processor, and a commit arriving while `isProcessingCommit()` is true is likewise not signaled. The main thread only unblocks when the currently‑running `StageWorkRequest.doWork()` finishes and its `finally` block executes the `if (!queuedRequests.isEmpty() || !committedRequests.isEmpty()) wakeup();` at lines 306–310 — i.e. one commit round‑trip at a time.

**3) Why only these two clients get killed**

Every follower's `NIOServerCnxn` is fed by this same single‑writer‑at‑a‑time gate, so all clients on that follower share the outage. The ClientCnxn's `SessionTimeoutException` at 1155 only fires when `readTimeout - idleRecv <= 0`:

- 10 s local sessions on 127.0.0.1:24551 → `readTimeout = 6666 ms`. Any window in which the gate above is closed for ≥ 6.666 s takes them down (matching the log's `6666ms / 6668ms / 6669ms` values).
- 40 s sessions on port 2181 → `readTimeout = 26 666 ms`, which is longer than the observed stalls, so they never trip the guard. And every busy local session on `myid=2/3` (e.g. `0x2a008cd5e4e0000` with 4 473 log lines) has an in‑flight response often enough that `idleRecv` never reaches 6666 ms, so those sessions survive even though they run on the same broken pipeline.

**4) The chain that produces `KeeperException.ConnectionLoss`**

Once the client's `SendThread` throws `SessionTimeoutException`:
- Line 1207 logs the "Session inactive – no server traffic for 6666ms …" INFO message you see.
- Falls through to the `cleanup()` path at lines 1221 (which walks `pendingQueue` and calls `conLossPacket(p)` on every packet still awaiting a reply) and enqueues a `Disconnected` `WatchedEvent` at 1223–1226.
- `conLossPacket` sets `p.replyHeader.setErr(KeeperException.Code.CONNECTIONLOSS)`; the caller thread returns from `submitRequest` and `KeeperException.create(...)` produces the `ConnectionLossException` the application sees.

### Summary of the failure path

The failing branches, in order:

1. Client submits an ephemeral `OpCode.create`; `FollowerIngressProcessor.processRequest` (`FollowerIngressProcessor.java:108`) synthesizes a global `createSession` upgrade via `QuorumZooKeeperServer.checkUpgradeSession` (`QuorumZooKeeperServer.java:65-83`), and enqueues **both** the upgrade and the original create to `StagedRequestProcessor.queuedRequests`.
2. `StagedRequestProcessor.run` (line 172) hits `needCommit(request) == true` for the upgrade and takes the `nextPending.set(request)` branch (line 173).
3. From then on, the guard `!isWaitingForCommit() && !isProcessingCommit()` at line 169 is false, so no further items are pulled off `queuedRequests` — client PINGs stack up untouched.
4. The suppressed wakeups in `commit` (line 328) and `processRequest` (line 341) mean commits/pings arriving during the round trip do not wake the parked main thread; forward progress is paced strictly by the worker's `finally` wakeup at lines 306–310, one committed request at a time.
5. Until the leader's commit for the upgrade — and then for the create — round‑trips through the follower's `StageWorkThread` and clears `currentlyCommitting`, the follower emits nothing on this session's socket.
6. Meanwhile, the client's `SendThread` sees `to = readTimeout - clientCnxnSocket.getIdleRecv() <= 0` at `ClientCnxn.java:1155` (with `readTimeout = 6666 ms`), throws `SessionTimeoutException`, and calls `cleanup()` — which walks `pendingQueue` and marks every outstanding request as `CONNECTIONLOSS` via `conLossPacket`, producing the observed `KeeperException.ConnectionLoss` at the application layer.

The 40 s clients on port 2181 traverse the identical pipeline; they simply never sit idle long enough to satisfy the `to <= 0` guard, which is why the failure appears specific to the two 10 s local‑session clients even though the underlying gate is shared by every session on that follower.
