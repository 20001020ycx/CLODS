Based on the code I've now confirmed, here is the definitive root-cause diagnosis.

## Root Cause

The failure is a **head-of-line blocking of client PINGs on the follower**, caused by the way `StagedRequestProcessor` serializes its main thread on every write request. It is *not* a network problem, and it is *not* a bug on the leader ACK path — the leader `tryToCommit`/`processAck` behavior, while subtle, is not what starves this session. The follower's own request pipeline is what stops answering the client.

### The exact code that dictates the failure

**File:** `src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java`

1. **Outer wait predicate — lines 155–161** (this is the primary culprit):

   ```java
   synchronized(this) {
       while (
           !stopped &&
           ((queuedRequests.isEmpty() || isWaitingForCommit() || isProcessingCommit()) &&
            (committedRequests.isEmpty() || isProcessingRequest()))) {
           wait();
       }
   }
   ```

   The left conjunct causes the main thread to stop polling `queuedRequests` whenever **either**
   - `isWaitingForCommit()` (i.e., `nextPending != null` — a write has been forwarded to the leader and we're awaiting its COMMIT), **or**
   - `isProcessingCommit()` (i.e., `currentlyCommitting != null` — a worker is still applying the last commit),

   is true. Client PINGs (which arrive as `OpCode.ping`, hit the `default` branch of `needCommit()` at line 145–146, and therefore should be dispatched straight through to a worker) sit in `queuedRequests` unclaimed during those windows.

2. **Inner poll loop — lines 169–177**:

   ```java
   while (!stopped && !isWaitingForCommit() &&
          !isProcessingCommit() &&
          (request = queuedRequests.poll()) != null) {
       if (needCommit(request)) {
           nextPending.set(request);   // ← after this, the guard fails and the loop exits
       } else {
           sendToNextProcessor(request);
       }
   }
   ```

   The moment a write is polled from `queuedRequests`, `nextPending` is set and the loop condition `!isWaitingForCommit()` immediately becomes false. Any PINGs that were queued *behind* that write are left in the queue until the whole commit round-trip completes (leader propose → quorum ACK → follower COMMIT → worker `TerminalRequestProcessor.processRequest`, which itself takes `synchronized (zks.outstandingChanges)`).

3. **Wakeup is *skipped* when a request is queued while a write is in flight — lines 340–343**:

   ```java
   public void processRequest(Request request) {
       ...
       queuedRequests.add(request);
       if (!isWaitingForCommit()) {   // ← if a write is pending, no wakeup
           wakeup();
       }
   }
   ```

   A PING that arrives while `nextPending != null` is enqueued silently. It relies on the eventual `wakeup()` from the worker's `finally` block (lines 306–311). That wakeup only fires *after* the commit has been applied — which in a sustained write stream means the main thread just cycles from one write to the next, never draining the accumulating pings.

4. **The `TaskExecutorPool` sessionId-affinity does NOT save us here**:

   `sendToNextProcessor` (line 269) hashes on `request.sessionId`, so different sessions land on different workers. But that affinity is *downstream* of the bottleneck. The main thread is a single serialization point that must set `nextPending`, wait for the matching COMMIT to arrive in `committedRequests`, then dispatch to the worker via `processCommitted()` (lines 198–242), then wait for `currentlyCommitting` to clear. Only after that whole sequence can it poll the next PING from `queuedRequests`. The workers are irrelevant to the stall.

### Trigger workload (from `logs/symptom.log`)

Session `0x4a00196f74a0016` is running a `create`/`delete` loop against `/loadtest/…`. Each of those is a `needCommit()==true` op (lines 133–139), so each one forces the follower's main thread through the full "set `nextPending` → wait for COMMIT → set `currentlyCommitting` → wait for worker → clear" cycle.

While that cycle repeats without gaps, the pings from other sessions (including `0x1a008cd5e440000`) accumulate in `queuedRequests` and are not dispatched to their workers, so `TerminalRequestProcessor` never emits a ping response.

### How that becomes the client-side symptom

**File:** `src/java/main/org/apache/zookeeper/ClientCnxn.java`

- `SendThread.run()` (around line 1136) computes:

  ```java
  to = readTimeout - clientCnxnSocket.getIdleRecv();
  ```

  where `readTimeout = 2 * sessionTimeout / 3 ≈ 6666 ms` for a 10 s session.

- **Lines 1155–1161** — the exact throwing branch:

  ```java
  if (to <= 0) {
      String warnInfo = "Session inactive - no server traffic for "
          + clientCnxnSocket.getIdleRecv()
          + "ms for sessionid 0x"
          + Long.toHexString(sessionId);
      LOG.warn(warnInfo);
      throw new SessionTimeoutException(warnInfo);
  }
  ```

- The catch that logs the observed line uses `RETRY_CONN_MSG` at **line 1207** (`"closing socket connection and attempting reconnect"`), producing verbatim:

  ```
  Session inactive - no server traffic for 6666ms for sessionid 0x1a008cd5e440000, closing socket connection and attempting reconnect
  ```

- The socket close raises the outstanding, unanswered request(s) with `KeeperException.ConnectionLoss`, which is what the application sees.

## Failure chain (branch-by-branch)

1. Load client on session `0x4a00196f74a0016` submits a continuous stream of `create`/`delete` writes → `needCommit()` returns `true` (StagedRequestProcessor.java:133–139).
2. Every such write forces `nextPending.set(request)` at StagedRequestProcessor.java:173, and the inner loop exits due to the `!isWaitingForCommit()` guard at line 169.
3. The outer wait at StagedRequestProcessor.java:156–161 refuses to poll `queuedRequests` again until the corresponding COMMIT arrives and the worker finishes (`isProcessingCommit()` clears).
4. Client PINGs from session `0x1a008cd5e440000` are enqueued via `processRequest` (line 340), but the `if (!isWaitingForCommit()) wakeup()` guard at line 341 is false, so no wakeup — they simply sit behind the in-flight write.
5. The next `wakeup()` (worker's `finally`, lines 306–311) races immediately into another `create`/`delete` from the load session, restarting steps 2–4. The PING is starved for the full duration.
6. On the client side, `clientCnxnSocket.getIdleRecv()` grows because *no* server bytes are arriving (no ping reply, no other response). Once it reaches `readTimeout` (6666 ms) the check `to <= 0` at ClientCnxn.java:1155 fires and throws `SessionTimeoutException` at line 1161.
7. The `SendThread` catch path logs `RETRY_CONN_MSG` at ClientCnxn.java:1207 — the observed line — and closes the socket. Outstanding requests are completed with `KeeperException.ConnectionLoss`.

## Why the leader/`tryToCommit` path is *not* the culprit here

I considered whether the `Leader.processAck` "cascade only for `OpCode.reconfig`" branch (Leader.java:842–849) could leave a proposal uncommitted and thereby starve the follower. That branch does exist, but the workload in the log is exclusively `create`/`delete` — those proposals ACK, then `tryToCommit` is called *for that same proposal* directly (Leader.java around line 800) with the standard `outstandingProposals.containsKey(zxid-1)` guard at line 702. As long as ACKs arrive roughly in-order (which they do in the trace), each write is committed and the follower's `stagedRequestProcessor.commit(request)` is called (FollowerZooKeeperServer.java:111). The follower is receiving commits fine; what it is *not* doing is servicing the pings interleaved between them.

## One-line summary

`StagedRequestProcessor`'s main thread predicate at **`StagedRequestProcessor.java:156–161`** (combined with the write-setting exit at **line 169–173** and the missed `wakeup()` at **line 341**) allows a sustained stream of writes from one session (`0x4a00196f74a0016`) to head-of-line-block PINGs of another session (`0x1a008cd5e440000`) in `queuedRequests`, so the client's `ClientCnxn.SendThread` reaches `to <= 0` at **`ClientCnxn.java:1155`**, throws `SessionTimeoutException` at line **1161**, and logs the observed message with `RETRY_CONN_MSG` at line **1207**, surfacing to the application as `KeeperException.ConnectionLoss`.
