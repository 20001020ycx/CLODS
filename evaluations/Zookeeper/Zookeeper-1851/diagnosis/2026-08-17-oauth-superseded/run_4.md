## Root Cause

The failure is not a network problem — it is the server-side pipeline of the ensemble on port `24551` serializing pings behind an in‑flight write, combined with a very short 10 000 ms negotiated session timeout. When the pipeline delay exceeds `readTimeout` (≈ 6 666 ms), the client's own timeout check trips and turns every outstanding call into `KeeperException.ConnectionLoss`.

## Where the exception is actually thrown (client)

`source/src/java/main/org/apache/zookeeper/ClientCnxn.java` — inside `SendThread.run()`:

```
1118:  if (state.isConnected()) {
…
1150:      to = readTimeout - clientCnxnSocket.getIdleRecv();
1151:  } else {
1152:      to = connectTimeout - clientCnxnSocket.getIdleRecv();
1153:  }
1154:
1155:  if (to <= 0) {
1156:      throw new SessionTimeoutException(
1157:              "Session inactive - no server traffic for "
1158:                      + clientCnxnSocket.getIdleRecv() + "ms"
1159:                      + " for sessionid 0x"
1160:                      + Long.toHexString(sessionId));
1161:  }
```

The exact log message the user sees is produced here (line 1157). The two branches that dictate the path are:

- `state.isConnected() == true` (line 1118) → `to = readTimeout − clientCnxnSocket.getIdleRecv()`.
- `to <= 0` (line 1155) → throw `SessionTimeoutException`.

`readTimeout` is fixed to 6 666 ms because of the assignment in `onConnected` (line 1338 of the same file):

```
1338:  readTimeout = negotiatedSessionTimeout * 2 / 3;
```

The server logged `Established session 0x1a008cd5e440000 with negotiated timeout 10000 …`, so `readTimeout = 10 000 × 2 / 3 = 6 666`. This is why the error message always says `6666ms` (with ±1 rounding noise, hence 6667/6668/6669).

The `SessionTimeoutException` is caught in the same run loop at lines 1204‑1230 and translated into a socket close + reconnect; every packet that was in `pendingQueue`/`outgoingQueue` is then completed via `conLossPacket()` in `cleanup()` (lines 1289‑1308), which is what surfaces to the caller as `KeeperException.ConnectionLoss`.

## Why `idleRecv` reaches `readTimeout` (server)

The affected clients are talking to the QuorumPeer ensemble on `127.0.0.1:24551`. That ensemble uses a **non‑standard follower pipeline**:

`source/src/java/main/org/apache/zookeeper/server/quorum/FollowerZooKeeperServer.java`

```
69:  @Override
70:  protected void setupRequestProcessors() {
71:      RequestProcessor finalProcessor = new TerminalRequestProcessor(this);
72:      stagedRequestProcessor = new StagedRequestProcessor(finalProcessor,
73:                                Long.toString(getServerId()), true);
74:      stagedRequestProcessor.start();
75:      firstProcessor = new FollowerIngressProcessor(this, stagedRequestProcessor);
76:      ((FollowerIngressProcessor) firstProcessor).start();
…
```

Every client packet — including a `ping` (xid = −2) — enters through `ZooKeeperServer.submitRequest` → `FollowerIngressProcessor.processRequest` → and then hits `StagedRequestProcessor.processRequest`. There is no fast path for pings.

The stall is in `StagedRequestProcessor.run()` in `source/src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java`. Three coupled branches serialize everything behind a pending write:

1. **Wait predicate** (lines 154‑161) — the main thread sleeps whenever *either* the queued side cannot be drained *or* the committed side cannot be applied:

   ```
   154:  while (!stopped) {
   155:      synchronized(this) {
   156:          while (
   157:              !stopped &&
   158:              ((queuedRequests.isEmpty() || isWaitingForCommit() || isProcessingCommit()) &&
   159:               (committedRequests.isEmpty() || isProcessingRequest()))) {
   160:              wait();
   161:          }
   ```

2. **Inner drain loop** (lines 169‑177) — only drains `queuedRequests` when there is neither a pending write nor a commit currently executing:

   ```
   169:  while (!stopped && !isWaitingForCommit() &&
   170:         !isProcessingCommit() &&
   171:         (request = queuedRequests.poll()) != null) {
   172:      if (needCommit(request)) {
   173:          nextPending.set(request);           // now isWaitingForCommit() == true
   174:      } else {
   175:          sendToNextProcessor(request);
   176:      }
   177:  }
   ```

   Once a write is popped and `nextPending` is set, the loop exits and *every subsequent request behind it in `queuedRequests` (including pings) is held there*.

3. **`processCommitted`** (lines 198‑242) — cannot advance while any worker is running (`isProcessingRequest()` == `numRequestsProcessing != 0`), and cannot cut ahead of the queue either:

   ```
   198:  protected void processCommitted() {
   199:      Request request;
   200:
   201:      if (!stopped && !isProcessingRequest() &&
   202:              (committedRequests.peek() != null)) {
   ...
   209:          if ( !isWaitingForCommit() && !queuedRequests.isEmpty()) {
   210:              return;
   211:          }
   ```

The `wakeup` bookkeeping done by the other two mutators is the reason a queued ping does not shortcut this state:

- `processRequest` (lines 333‑344) skips the notify when a write is pending:

  ```
  340:  queuedRequests.add(request);
  341:  if (!isWaitingForCommit()) {
  342:      wakeup();
  343:  }
  ```

  Because `nextPending` is set, `isWaitingForCommit()` is true, so a newly queued ping does **not** trigger `notifyAll()`.

- `commit` (lines 320‑331) only wakes the main thread if a commit isn't already in flight:

  ```
  327:  committedRequests.add(request);
  328:  if (!isProcessingCommit()) {
  329:      wakeup();
  330:  }
  ```

- The worker's `finally` block only wakes the main thread when `numRequestsProcessing` returns to 0 (lines 292‑313):

  ```
  306:  if (numRequestsProcessing.decrementAndGet() == 0) {
  307:      if (!queuedRequests.isEmpty() ||
  308:          !committedRequests.isEmpty()) {
  309:          wakeup();
  310:      }
  311:  }
  ```

Putting the branches together, the ping cannot be serviced until:

1. the `COMMIT` for the write ahead of it arrives from the leader (`FollowerZooKeeperServer.commit` at lines 97‑112, which calls `stagedRequestProcessor.commit`);
2. `processCommitted` (line 201: `!isProcessingRequest()` must be true) can then match `nextPending` and schedule the write to the pool via `sendToNextProcessor` (line 234 → line 267‑270);
3. that worker's `StageWorkRequest.doWork` finishes — its `finally` clears `currentlyCommitting` (line 298) and decrements `numRequestsProcessing` to 0 (line 306) which finally calls `wakeup()`;
4. the main loop reruns the inner while at lines 169‑177 and drains the pings via `sendToNextProcessor`;
5. one of the 32 `StageWork` threads finally reaches `TerminalRequestProcessor.processRequest` case `OpCode.ping` (`source/.../server/TerminalRequestProcessor.java` lines 180‑190) and calls `cnxn.sendResponse(new ReplyHeader(-2, …))`.

That whole chain has to complete within `readTimeout = 6 666 ms`, but the follower serializes *every* queued read/ping on that pipeline behind each in‑flight write commit from any session. This is confirmed by the log:

- Pings for sessions on the 2181 factory (e.g. `0x1a00196f7470005`) are visible every few seconds through `FollowerIngressProcessor → StagedRequestProcessor → TerminalRequestProcessor`.
- For the affected sessions on the 24551 ensemble (`0x1a008cd5e440000`, `0x1a008cd5e440001`) `grep '1a008cd5e440000 type:ping'` returns **zero** hits — the pings queue in `StagedRequestProcessor.queuedRequests` behind writes and never reach `TerminalRequestProcessor` in time.
- The disconnect always fires at ≈ `readTimeout` (6666–6669 ms) and the session is re‑established with the same 10 s timeout and the loop repeats every ~5 min.

## Summary of the failure branches

Client (`ClientCnxn.java`):
- L1118 `state.isConnected() == true` → L1150 `to = readTimeout − getIdleRecv()`.
- L1155 `to <= 0` → throw `SessionTimeoutException` (with `getIdleRecv() == 6666`, because L1338 `readTimeout = negotiatedSessionTimeout * 2 / 3` and the log shows `negotiated timeout 10000`).
- Caught in the outer `try/catch` at L1193, translated to `Disconnected` + `cleanup()` at L1289‑1308, which fails every in‑flight packet with `ConnectionLoss`.

Server (`StagedRequestProcessor.java`, follower pipeline set up in `FollowerZooKeeperServer.setupRequestProcessors` L69‑79):
- L169‑171 `!isWaitingForCommit() && !isProcessingCommit()` — queued pings stay queued while a write is pending.
- L156‑161 wait predicate + L341 (`if (!isWaitingForCommit()) wakeup();`) + L328 (`if (!isProcessingCommit()) wakeup();`) + L306‑311 (worker `finally` only wakes when `numRequestsProcessing` hits 0) — the main loop cannot advance to the pings until the whole commit round trip completes.
- L201 `!isProcessingRequest()` — even after `nextPending` is cleared, `processCommitted` waits for the busy worker to drain, extending the stall.

With a 10 s negotiated timeout (client sends a value ≤ min/maxSessionTimeout that gets negotiated to 10 000 ms), the client's `readTimeout` window is only 6 666 ms — smaller than the tail latency this serialized pipeline can produce under sustained write traffic — so the client's own `SessionTimeoutException` fires and every outstanding call surfaces to the application as `KeeperException.ConnectionLoss`.
