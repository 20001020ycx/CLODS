I've traced enough of the code and log to formulate the diagnosis. Here is the analysis:

## Root cause

**The failure surface** — the client-side message you see — is thrown in `ClientCnxn.java`:

- `ClientCnxn.SendThread.run()` at **line 1150**: `to = readTimeout - clientCnxnSocket.getIdleRecv();` (with `readTimeout = negotiatedSessionTimeout * 2 / 3`, set at line 1338 → 6666 ms for the 10 000 ms session timeout the log negotiated).
- **Line 1155–1160**: `if (to <= 0) throw new SessionTimeoutException("Session inactive - no server traffic for " + …)`. This is entered whenever the client sees no bytes from the server for `readTimeout` ms.
- The caller (**line 1206–1207**) catches `SessionTimeoutException` and logs it with `RETRY_CONN_MSG` (`", closing socket connection and attempting reconnect"` defined at line 1096–1097), which is exactly the log entry cited. Then `cleanup()` (line 1221) and a `Disconnected` `WatchedEvent` are queued (line 1223), which is the `ConnectionLoss` surface the caller's ZK client sees.

So the client-side branch is not the bug — it fires correctly because the server truly did stop sending. The bug is why the server stops sending.

**Server-side (why no traffic for > 6666 ms)** — search the log for the server myid:1 (the follower on port 24551 that our session `0x1a008cd5e440000` is attached to) and grep it against `StagedRequestProcessor@325`/`@338` (the DEBUG line numbers this build produces for `commit()` line 325 and `processRequest()` line 338 of `src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java`). Every stall in the log — `18:53:53,725 → 18:53:59,438`, then again ~5:50 later, and again, and again, matching each `Session inactive` line — is a gap of ~5.7 s where **that processor's main thread performs no work at all** while the NIO accept thread keeps running (the `ruok` health checks and the "Unable to read additional data from client sessionid …, likely client has closed socket" line at 18:53:56 both fire from unrelated threads during the stall).

The stall is dictated by the head-of-line-blocking rules in `StagedRequestProcessor` on the follower (this is the class installed by `FollowerZooKeeperServer.setupRequestProcessors()` at `FollowerZooKeeperServer.java:71`). The specific conditions:

1. **`StagedRequestProcessor.run()` — inner poll loop, lines 169–177**:
   ```java
   while (!stopped && !isWaitingForCommit() &&
          !isProcessingCommit() &&
          (request = queuedRequests.poll()) != null) {
       if (needCommit(request)) {
           nextPending.set(request);              // line 173
       } else {
           sendToNextProcessor(request);
       }
   }
   ```
   As soon as a write is pulled and set in `nextPending` (line 173), the guard `!isWaitingForCommit()` is false and this loop stops. **Every subsequent request in `queuedRequests`, including pings from every other session on this follower, is now blocked** until that one write's commit arrives from the leader and its worker returns.

2. **`processCommitted()` — lines 198–241**: the guard at line 201 (`!isProcessingRequest()`) prevents committing while any worker is still busy, and the guard at line 209 (`!isWaitingForCommit() && !queuedRequests.isEmpty()`) makes it back off when reads are queued but nothing is waiting. In tandem with the "else" branch at lines 235–239, ANY unrelated commit sets `currentlyCommitting` — so `isProcessingCommit()` returns true and re-blocks the inner poll loop (line 170) again, even though the commit is for a different session.

3. **Main-thread wait at lines 155–161**:
   ```java
   synchronized(this) {
       while (!stopped &&
              ((queuedRequests.isEmpty() || isWaitingForCommit() || isProcessingCommit()) &&
               (committedRequests.isEmpty() || isProcessingRequest()))) {
           wait();
       }
   }
   ```
   When a write is pending (isWaitingForCommit=true) *and* an unrelated commit is being applied (isProcessingCommit=true) *and* workers are still busy (isProcessingRequest=true), both AND-clauses are true, so the main thread parks in `wait()`. It can only be woken by:
   - `commit()` (lines 320–331) — but line 328 short-circuits with `if (!isProcessingCommit()) wakeup();`, so if a commit is already in flight on a worker no wakeup is sent — the new commit just piles in `committedRequests`.
   - `processRequest()` (lines 333–344) — but line 341 short-circuits with `if (!isWaitingForCommit()) wakeup();`, so while a write is pending, incoming pings/reads pile in `queuedRequests` *without* signaling the main thread.
   - `StageWorkRequest.doWork()`'s finally (lines 292–313) — but wakeup is only issued when `numRequestsProcessing.decrementAndGet() == 0` (line 306) *and* one of the queues is non-empty at that instant (lines 307–310). While the leader's own network hop is servicing the pending write, the follower's main thread is idle and neither producer thread will signal it.

4. **The specific branch that fires on each cycle**: on the follower a pending write goes through the write-blocking phase, then the leader eventually commits it and `commit()` at line 320 finally does wake the main thread (line 328 sees `!isProcessingCommit()`). Between that outbound-commit-not-yet-arriving window on the leader and the moment the follower's worker finishes running the terminal processor for the write, **the follower services no other session's traffic**. When the accumulated `now - lastRecv` on any idle client attached to the follower exceeds `readTimeout` (6666 ms), that client throws at `ClientCnxn.java:1155`. That's precisely what the log shows: the follower's `StagedRequestProcessor` main thread is idle from 18:53:53,725 until 18:53:59,438 — about 5.7 s — because a write for another session was pending (`nextPending != null`) with no matching commit yet available, and the corresponding wait predicate at lines 156–159 was true. The follower's other threads (NIO acceptor, connection expirer) are still alive but they cannot deliver responses without the processor pipeline.

So the failure path, restated in one sentence: `StagedRequestProcessor` blocks ALL request throughput on a follower whenever a single write is between `nextPending.set(request)` (line 173) and the arrival of its matching commit through `commit()` (line 320); during that window the guard `!isWaitingForCommit() && !isProcessingCommit()` at lines 169–170 keeps `queuedRequests.poll()` from advancing, so pings for every other session on that follower sit unserviced, and any client whose `readTimeout` (`= 2/3 * negotiatedSessionTimeout` per `ClientCnxn.java:1338`) elapses first crosses the `to <= 0` branch at `ClientCnxn.java:1155` and surfaces as `ConnectionLoss`.
