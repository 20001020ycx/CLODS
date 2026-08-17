## Root-Cause Diagnosis

### The failure path (one-sentence version)

Under heavy write load, the custom `StagedRequestProcessor` blocks **every** request in `queuedRequests` — including the harmless PING that keeps sessions alive — behind the single "in-flight" write held in `nextPending`. When the leader's per-write commit stall (produced by follower ack backlog visible in the log) exceeds the client's read-timeout (`2/3 × sessionTimeout` = 6666 ms for a 10 000 ms session), the client's `ClientCnxn.doTransport()` sees no server traffic for the timeout window, throws `SessionTimeoutException`, tears down the socket, and every in-flight call surfaces as `KeeperException.ConnectionLoss`.

The problem is **not** a lost-wakeup deadlock; it is a design choice in `StagedRequestProcessor` that promotes any single slow write into a full-pipeline stall visible to every client on that server — including the pings that gate the session-timeout detector on the client.

---

### 1. Client side — where the log message is produced

`src/java/main/org/apache/zookeeper/ClientCnxn.java`

* **Line 1155–1161** — the branch that fires the timeout:
  ```java
  if (to <= 0) {
      throw new SessionTimeoutException(
              "Session inactive - no server traffic for "
                      + clientCnxnSocket.getIdleRecv() + "ms"
                      + " for sessionid 0x"
                      + Long.toHexString(sessionId));
  }
  ```
  `to = readTimeout - clientCnxnSocket.getIdleRecv()`, and `readTimeout = 2 * sessionTimeout / 3`. For the sample session (`0x1a008cd5e440000`, `sessionTimeout = 10000`), `readTimeout = 6666`, matching the "no server traffic for 6666ms" wording in the log verbatim.

* **Line 1206–1207** — where the observed INFO message is emitted (`ClientCnxn$SendThread@1207`):
  ```java
  else if (e instanceof SessionTimeoutException) {
      LOG.info(e.getMessage() + RETRY_CONN_MSG);
  }
  ```

* **Line 1221** — `cleanup();` closes the socket, marks the connection lost, and completes every outstanding packet with `KeeperException.ConnectionLoss` — the exception the user sees.

So the client-side condition that must be true for the reported symptom to fire is simply: **no bytes were received for 6666 ms** while the connection was in `SendThread` service. There is no bug on the client; the client is faithfully reporting that the server went silent.

---

### 2. Server side — why the server goes silent

The client's silence is imposed by `StagedRequestProcessor`, whose whole design is captured in its own Javadoc (`src/java/main/org/apache/zookeeper/server/quorum/StagedRequestProcessor.java`, line 63–64):

> "The current implementation solves the third constraint by simply allowing no read requests to be processed in parallel with write requests."

That is exactly the property that causes the failure. The specific branches:

**(a) A write pins the pipeline.** `run()`, line 169–177:

```java
while (!stopped && !isWaitingForCommit() &&
       !isProcessingCommit() &&
       (request = queuedRequests.poll()) != null) {
    if (needCommit(request)) {
        nextPending.set(request);          // <-- pipeline is now blocked
    } else {
        sendToNextProcessor(request);
    }
}
```

`needCommit()` (line 131–148) returns `true` for `create` / `delete` / `setData` / `reconfig` / `multi` / `setACL`, and (on the leader) also for global `createSession` / `closeSession`. The HBase-style workload in the log fires those op-codes constantly, so `nextPending` is continually re-armed.

After `nextPending.set(request)`, `isWaitingForCommit()` (line 123) becomes `true`, and the loop guard `!isWaitingForCommit()` at line 169 is `false`. **No further request will be pulled from `queuedRequests` — pings included** — until the write is committed AND its worker finishes.

**(b) Newly-arriving pings cannot even wake the run loop.** `processRequest()`, line 340–343:

```java
queuedRequests.add(request);
if (!isWaitingForCommit()) {
    wakeup();
}
```

A PING that arrives while a write is pending is enqueued but the wake is **skipped** because `isWaitingForCommit() == true`. So the ping sits there silently; it can only be serviced when a later event (the commit or a worker completion) happens to wake the loop.

**(c) The outer wait cements the stall.** `run()`, line 155–161:

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

While `isWaitingForCommit() == true` and no matching commit has arrived, the first clause is `true`; while `committedRequests` is empty (no commit yet), the second clause is `true`. So the thread parks **even though `queuedRequests` contains pings** — again, exactly the point of the design.

**(d) Un-blocking requires a full commit round-trip.** `processCommitted()`, line 220–234, matches `nextPending`, clears it, and dispatches on the worker pool:

```java
Request pending = nextPending.get();
if (pending != null &&
    pending.sessionId == request.sessionId &&
    pending.cxid == request.cxid) {
    pending.setHdr(request.getHdr());
    pending.setTxn(request.getTxn());
    pending.zxid = request.zxid;
    currentlyCommitting.set(pending);   // isProcessingCommit == true now
    nextPending.set(null);
    sendToNextProcessor(pending);
}
```

The queue stays blocked (`isProcessingCommit()` is now `true`, so line 169 still refuses to poll pings) until the worker finishes in `StageWorkRequest.doWork()`'s finally block (line 298–311):

```java
currentlyCommitting.compareAndSet(request, null);
if (numRequestsProcessing.decrementAndGet() == 0) {
    if (!queuedRequests.isEmpty() || !committedRequests.isEmpty()) {
        wakeup();
    }
}
```

Only after this does the main thread finally re-enter the drain loop and pull the backed-up pings/reads.

**(e) The final processor further serializes the write path.** `TerminalRequestProcessor.processRequest`, line 102:

```java
synchronized (zks.outstandingChanges) {
    rc = zks.processTxn(request);
    ...
}
```

Even the PING response (line 180–189) has to walk through this processor, so the PING response is bottlenecked behind the same monitor that serializes every write's `processTxn` and outstanding-change trim.

**(f) Both roles route PING through the pipeline.** Confirmed in `LeaderZooKeeperServer.setupRequestProcessors()` (line 61–73) and `FollowerZooKeeperServer.setupRequestProcessors()` (line 69–79). In both roles the chain is `<Ingress> → StagedRequestProcessor → TerminalRequestProcessor`. There is no fast-path that lets a PING bypass the stalled `nextPending` slot on either the leader or the follower.

---

### 3. Why the stall lasts >6666 ms — the log corroborates it

The tail of `logs/symptom.log` shows the amplifier:

* `SyncThread:<myid>:Leader@584 - Count for zxid: 0x1000XXXXX is 1` for many consecutive zxids — only the leader's own self-ack has arrived; the followers have not yet acknowledged those proposals, so `Leader.tryToCommit(zxid)` (which is what would eventually call `StagedRequestProcessor.commit(request)` on line 320) cannot fire.
* `LearnerHandler-…:Leader@569 - proposal has already been committed, pzxid: X zxid: Y` — LearnerHandler catch-up spam showing followers running seconds behind.

Because `Leader.tryToCommit()` is `synchronized public` and its critical section synchronously calls `stagedRequestProcessor.commit(p.request)` while quorum is being gathered, the local `nextPending` sits armed for however long it takes the slowest of the ack-lagging followers to catch up. The log makes clear that under this workload this exceeds the 6666 ms client budget.

---

### 4. Exact logical conditions that dictate the failure path

Combining the above, the failure fires **iff all** of the following hold on the server the client is attached to:

1. `StagedRequestProcessor.needCommit(request) == true` for some request that got pulled by `run()` at line 172 → `nextPending.set(request)` at line 173.
2. The commit for that request does not arrive within `readTimeout` (`= 2 * sessionTimeout / 3` = 6666 ms in this run). While the log shows the leader waiting for follower quorum acks (`Count … is 1` for consecutive zxids), condition 1's `nextPending` slot stays occupied on the follower(s) that were forwarding writes for this session.
3. During that interval the guard `!isWaitingForCommit() && !isProcessingCommit()` at line 169 is `false`, so PINGs and reads queued in `queuedRequests` (including line 340's freshly-added ones — for which line 341's `if (!isWaitingForCommit())` gate suppresses `wakeup()`) are not dispatched, and `TerminalRequestProcessor.processRequest` at line 187 never runs to emit a PING reply.
4. The client's `ClientCnxn.doTransport()` reaches line 1155 with `to = readTimeout - clientCnxnSocket.getIdleRecv() <= 0`, throws `SessionTimeoutException`, logs the symptom message at line 1207, and calls `cleanup()` at line 1221 which fails all outstanding requests with `KeeperException.ConnectionLoss`.

If any one of these branches goes the other way — a lower write rate that lets `nextPending` clear inside 6666 ms, a workload of only pure reads (so `needCommit` never returns `true`), a session with `sessionTimeout` large enough that `readTimeout > commit-stall`, or a PING fast-path that bypasses `queuedRequests` — the symptom does not fire. The observed HBase-style workload in `symptom.log` violates every one of those escape hatches, which is why the client uniformly fails with `ConnectionLoss`.

---

### 5. The specific offending source-line summary

| Concern | File | Lines |
|---|---|---|
| Any write op arms the pipeline gate | `StagedRequestProcessor.java` | 131–148 (`needCommit`), 172–173 (`nextPending.set`) |
| Ping/read draining is gated on "no pending write" | `StagedRequestProcessor.java` | 169–170 (loop guard) |
| Outer wait keeps the thread parked with queued pings | `StagedRequestProcessor.java` | 156–161 |
| Enqueuing a ping while a write is pending does not wake the loop | `StagedRequestProcessor.java` | 340–343 |
| Commit-matching sets `currentlyCommitting`, still blocking drain until worker completes | `StagedRequestProcessor.java` | 220–234, 298–311 |
| Global monitor further serializes the response path (even PINGs) | `TerminalRequestProcessor.java` | 102 (`synchronized(zks.outstandingChanges)`), 187 (PING response) |
| Leader-side commit path that must complete for `nextPending` to clear | `Leader.java` | 702 (`tryToCommit`), 763 (`stagedRequestProcessor.commit`) |
| Client-side timeout branch that produces the log line | `ClientCnxn.java` | 1155–1161 (throw), 1206–1207 (log), 1221 (`cleanup()`) |

The root cause is therefore the `StagedRequestProcessor` gate at **line 169** of `StagedRequestProcessor.java`, together with the `processRequest` wake-suppression at **line 341** — an intentional "no reads in flight while a write is pending" policy that couples the client-visible session liveness (PING) to the tail latency of write commits, so any commit stall longer than `readTimeout` produces the observed `ConnectionLoss`.
