I now have enough evidence to finalize the diagnosis. The critical log lines above confirm the pipeline shape and expose the bottleneck.

# Root Cause Diagnosis

## The failure path in one sentence
The custom `StagedRequestProcessor` (replacing the stock `CommitProcessor`) plus `TaskExecutorPool` produce a **single‑in‑flight, single‑threaded commit pipeline** on every server. Under sustained write load the pipeline cannot keep up, request queues grow, and PINGs/reads for other sessions are trapped behind an ever‑lengthening chain of pending writes. When a session goes >6666 ms without any bytes from the server, the client fires `SessionTimeoutException` (surfaced to the caller as `ConnectionLoss`).

## Log evidence (from `/tmp/clods-diag-KrYy/logs/symptom.log`)

* Leader is `myid=7`. Session `0x4a00196f74a0016` (client on server 4) is running a create/delete storm:
  * Line 7900002: `Proposing:: ... zxid:0x10002048e` at `19:28:40,471`
  * Line 7900016: `Applying agreed submission:: ... zxid:0x100020462` at `19:28:40,472`
  * → 44‑txn lag.
  * Line 8072677: `Handling submission:: ... zxid:0x1000241c1` at `19:28:51,006`
  * Line 8072678: `Applying agreed submission:: ... zxid:0x10002416e` at `19:28:51,007`
  * → lag grown to 83 txns after 11 s, still rising.

* Every commit dispatch shows the same thread taking the work all the way to the leaf processor:
  * `[SyncThread:7:StagedRequestProcessor@164] - Applying agreed submission::` (commit is enqueued from the SyncThread / LearnerHandler)
  * `[StagedRequestProcessor:7:TerminalRequestProcessor@88] - Handling submission::` (the *same* leader main thread is running `TerminalRequestProcessor.processRequest` at line 91 — i.e. work runs on the `StagedRequestProcessor:7` thread, not on a pool worker). This is inline execution via `TaskExecutorPool`.

The affected session in the symptom, `0x1a008cd5e440000`, decodes to server 1 (top nibble 1). Server 1 is a follower; every leader COMMIT is fed to that follower's `StagedRequestProcessor` which is subject to the same single‑threaded serialization — so its clients (including `0x1a008cd5e440000`) get no PING responses while it is draining leader commits.

## Exact code paths that dictate the failure

All line numbers below refer to the source at `/tmp/clods-diag-KrYy/source`.

### 1. Server-side pipeline is one-in-flight and single-threaded

`StagedRequestProcessor.java:156‑161` — outer wait condition:
```java
while (
    !stopped &&
    ((queuedRequests.isEmpty() || isWaitingForCommit() || isProcessingCommit()) &&
     (committedRequests.isEmpty() || isProcessingRequest()))) {
    wait();
}
```
As soon as a write is polled and `nextPending` is set (`isWaitingForCommit()==true`), the first clause becomes TRUE; if `committedRequests` is empty the second is also TRUE → the main thread **blocks in `wait()`**. PINGs and reads already in `queuedRequests` cannot be serviced during this window.

`StagedRequestProcessor.java:169‑177` — inner drain loop:
```java
while (!stopped && !isWaitingForCommit() &&
       !isProcessingCommit() &&
       (request = queuedRequests.poll()) != null) {
    if (needCommit(request)) {
        nextPending.set(request);   // <-- sets isWaitingForCommit()==true, then exits
    } else {
        sendToNextProcessor(request);
    }
}
```
The guard `!isWaitingForCommit() && !isProcessingCommit()` short-circuits the drain as soon as the first write is peeled off. Any PINGs sitting behind that write in `queuedRequests` are stranded until this pending write's COMMIT arrives.

`StagedRequestProcessor.java:198‑242` — `processCommitted()` processes **at most one** committed request per outer‑loop iteration. Combined with (1) and (2), the whole pipeline advances strictly one commit at a time.

`StagedRequestProcessor.java:267‑270` — `sendToNextProcessor` hands work to `workerPool.schedule(...)`.

### 2. `TaskExecutorPool` inlines the work on the main thread

`TaskExecutorPool.java:110‑143` — `schedule(WorkRequest, id)`:
```java
int size = workers.size();
if (size > 0) {
    ...
    worker.execute(scheduledWorkRequest);
} else {
    // When there is no worker thread pool, do the work directly
    // and wait for its completion
    scheduledWorkRequest.start();
    try {
        scheduledWorkRequest.join();          // <-- MAIN THREAD BLOCKS HERE
    } catch (InterruptedException e) { ... }
}
```
The log lines `[StagedRequestProcessor:7:TerminalRequestProcessor@88]` prove that in this deployment the pool is behaving as the `size == 0` branch: every dispatched commit blocks the `StagedRequestProcessor:N` thread until `Leader.ToBeAppliedRequestProcessor → TerminalRequestProcessor.processRequest` (`TerminalRequestProcessor.java:89‑92` and downstream code that applies the txn, walks watches, sends the response) has finished. Nothing else on that server can advance during that time.

Additionally at `TaskExecutorPool.java:100‑102` the no-id variant hardcodes `id=0`, and even with the assignable pool, all traffic for the same session is pinned to a single executor — so session hot‑spots (like `0x4a00196f74a0016`) cannot benefit from parallelism across workers.

### 3. Leader enforces strict in‑order commit

`Leader.java:702` — `tryToCommit`:
```java
if (outstandingProposals.containsKey(zxid - 1)) {
    return false;      // wait, we can't commit yet
}
```
So one slow txn stalls every subsequent commit; the queue behind it accumulates until every follower's `StagedRequestProcessor` has drained the blocking one.

`Leader.java:763` — after `commit(zxid); inform(p);` calls `zk.stagedRequestProcessor.commit(p.request);` on the leader, and `Follower.processPacket` → `FollowerZooKeeperServer.commit(zxid)` (`FollowerZooKeeperServer.java:97‑112`) does the same on every follower. Every server therefore feels the same bottleneck.

### 4. Client-side timeout

`ClientCnxn.java:1150‑1161` (in `SendThread.run` inside the select loop):
```java
int to = readTimeout - clientCnxnSocket.getIdleRecv();
if (to <= 0) {
    throw new SessionTimeoutException(
        "Session inactive - no server traffic for "
        + clientCnxnSocket.getIdleRecv() + "ms"
        + " for sessionid 0x"
        + Long.toHexString(sessionId));
}
```
`readTimeout` is set to `negotiatedSessionTimeout * 2 / 3`; for the configured 10 s session timeout it equals **6666 ms**. When the server (server 1 in this case) is monopolized by draining leader commits, no ping response or reply is transmitted, `getIdleRecv()` climbs past 6666, `to ≤ 0`, and the exception fires with exactly the reported message.

`ClientCnxn.java:1206‑1207` — the catch appends `RETRY_CONN_MSG`:
```java
} else if (e instanceof SessionTimeoutException) {
    LOG.info(e.getMessage() + RETRY_CONN_MSG);
```
producing `"…, closing socket connection and attempting reconnect"`. `cleanup()` follows and the application sees `KeeperException.ConnectionLoss`.

## Sequence of events that leads to the symptom

1. Client on session `0x4a00196f74a0016` (server 4) launches a burst of ~16 000 create/delete ops in ~11 s (~1500 ops/s), all forwarded to the leader (server 7). `LeaderRequestProcessor → PrepRequestProcessor → ProposalRequestProcessor.processRequest` adds them to the leader's `StagedRequestProcessor.queuedRequests` (line 340 `queuedRequests.add(request)`) and calls `Leader.propose(...)`.
2. `StagedRequestProcessor:7` polls each write, sets `nextPending`, exits the inner loop (line 173), calls `processCommitted()` (empty), and re-enters `wait()` at line 160.
3. Followers ACK; on the fourth ACK per zxid `Leader.tryToCommit` fires and calls `stagedRequestProcessor.commit(request)` (line 763). `commit()` at `StagedRequestProcessor.java:320‑331` adds to `committedRequests` and wakes up the main thread.
4. Main matches the commit against `nextPending`, sets `currentlyCommitting`, and calls `sendToNextProcessor` (line 234) → `workerPool.schedule` → **inline execution on the same `StagedRequestProcessor:7` thread** (per log evidence and `TaskExecutorPool.java:132‑141`).
5. Because `processCommitted()` handles only **one** commit per iteration and each dispatch blocks main until the txn is applied and the response is sent, the leader falls behind: proposals grow faster than commits complete (44‑txn → 83‑txn backlog in 11 s).
6. Every follower runs the same one‑at‑a‑time drain of the COMMIT stream through its own single-threaded `StagedRequestProcessor`. On follower server 1 (which hosts session `0x1a008cd5e440000`), the main thread spends all its time on that stream and cannot service the session's PING requests queued in `queuedRequests` behind whatever write is currently `nextPending`.
7. After 6666 ms with no bytes reaching the client, `ClientCnxn.java:1155` fires `SessionTimeoutException`; the catch at 1206‑1207 logs the exact symptom string; the SendThread does `cleanup()` and enqueues a `Disconnected` event, which bubbles up as `KeeperException.ConnectionLoss` to every outstanding pending operation on that session.

## Summary of the "bug" — the specific branches at fault

| File / Line | Branch/Condition | Effect |
|---|---|---|
| `StagedRequestProcessor.java:158‑159` | `(isWaitingForCommit() OR isProcessingCommit())` gates outer wait | Main sleeps while a write is in‑flight; no forward progress on other requests |
| `StagedRequestProcessor.java:169‑171` | `!isWaitingForCommit() && !isProcessingCommit()` gates the drain | PINGs/reads behind a write in `queuedRequests` are stranded |
| `StagedRequestProcessor.java:198‑242` | `processCommitted()` handles **one** commit per iteration | Throughput ceiling of one commit per outer‑loop cycle |
| `TaskExecutorPool.java:132‑141` | `size == 0` branch → `start(); join();` | Downstream processors run on the main thread; whole pipeline serial |
| `TaskExecutorPool.java:125` (`id % size`) | Per‑session pinning | Even with pool workers, a single hot session cannot parallelize |
| `Leader.java:702` | `outstandingProposals.containsKey(zxid‑1)` | One slow txn blocks all subsequent commits |
| `ClientCnxn.java:1155‑1161` | `if (to <= 0) throw new SessionTimeoutException(...)` | Emits the exact symptom message when the follower goes silent >6666 ms |
| `ClientCnxn.java:1206‑1207` | `else if (e instanceof SessionTimeoutException)` | Appends `RETRY_CONN_MSG` and disconnects; caller sees `ConnectionLoss` |

The design regression versus stock `CommitProcessor` is that the modified class serializes **all** progress on `nextPending`/`currentlyCommitting` while `TaskExecutorPool` in its `size==0` mode collapses the entire downstream chain onto that single thread — producing the throughput cliff visible in the log and the client‑visible `Session inactive - no server traffic for 6666ms` symptom.
