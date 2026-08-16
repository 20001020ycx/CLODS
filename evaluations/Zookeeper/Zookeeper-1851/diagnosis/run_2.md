## Root cause

The `StagedRequestProcessor.needCommit()` switch table is missing the `OpCode.createExt` opcode (the extended-create used for e.g. `/app/svc4/item-9137` in the log). A `createExt` therefore takes the local-read path in the commit processor, is fed to `TerminalRequestProcessor` with no `TxnHeader`, and blows up `addCommittedProposal` on `getHdr().serialize(...)` with an NPE. The exception unwinds into `StageWorkRequest.cleanup()`, which calls `halt()` on the entire `StagedRequestProcessor`. After that the processor is dead: every subsequent `processRequest()`/`commit()` early-returns, so ping replies and normal replies stop flowing to any client attached to that server, which is exactly the "no server traffic for 6666ms" symptom.

## Timeline in the log (server myid:1)

- `[FollowerIngressProcessor:1:StagedRequestProcessor@338]` at 18:49:25,284 receives `type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown /app/svc4/item-9137` — a write with no leader zxid yet.
- Immediately (same ms) `[StageWorkThread-2:TerminalRequestProcessor@91]` "Handling submission" for the *same* `createExt` with `zxid:0xfffffffffffffffe` — proof it was dispatched down the pipeline without ever going through commit.
- `[StageWorkThread-2:TaskExecutorPool$ScheduledWorkRequest@163] WARN Unexpected exception` — the NPE.
- `[StageWorkThread-2:StagedRequestProcessor$StageWorkRequest@286] ERROR Downstream stage failed; cannot continue.`
- `[StagedRequestProcessor:1:StagedRequestProcessor@191] INFO StagedRequestProcessor loop terminated`.

From this point onward myid:1 never runs another `StagedRequestProcessor@325`/`@338` log line; clients bound to it (session `0x1a008cd5e440000` connecting to `127.0.0.1:24551`) stop hearing pings and get the "Session inactive – no server traffic for 6666ms" line, then `ConnectionLoss`.

## The specific branches

1. **The missing case — `StagedRequestProcessor.java:131-148`**

    ```java
    protected boolean needCommit(Request request) {
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
                return false;        // <-- OpCode.createExt (=15, ZooDefs.java:60) falls here
        }
    }
    ```

    Because `createExt` isn't listed, `needCommit(createExt) == false`.

2. **The wrong-branch dispatch — `StagedRequestProcessor.java:169-177`**

    ```java
    while (!stopped && !isWaitingForCommit() &&
           !isProcessingCommit() &&
           (request = queuedRequests.poll()) != null) {
        if (needCommit(request)) {
            nextPending.set(request);
        } else {
            sendToNextProcessor(request);   // <-- createExt taken here, header still null
        }
    }
    ```

    The write is handed to `TerminalRequestProcessor` immediately, so `request.getHdr()` is still `null` and `request.zxid` is still `0xfffffffffffffffe`.

3. **The NPE trigger — `Request.isQuorum` returns true for `createExt`, so `TerminalRequestProcessor.java:126-128` runs:**

    ```java
    if (request.isQuorum()) {                                   // Request.java:170 case OpCode.createExt -> true
        zks.getZKStateStore().addCommittedProposal(request);
    }
    ```

    which in `ZKStateStore.java:251` does

    ```java
    request.getHdr().serialize(boa, "hdr");   // NullPointerException — getHdr() is null
    ```

    The surrounding `try/catch` only catches `IOException`, so the NPE escapes the `synchronized(zks.outstandingChanges)` block, exits `processRequest`, and propagates through `StageWorkRequest.doWork` (its `finally` runs but rethrows).

4. **The catch that kills the processor — `TaskExecutorPool.java:154-166`**

    ```java
    try {
        if (stopped) { workRequest.cleanup(); return; }
        workRequest.doWork();
    } catch (Exception e) {
        LOG.warn("Unexpected exception", e);
        workRequest.cleanup();          // <-- taken on the NPE
    }
    ```

5. **The halt — `StagedRequestProcessor.java:283-290` then `346-353`**

    ```java
    public void cleanup() {
        if (!stopped) {
            LOG.error("Downstream stage failed; cannot continue.");
            StagedRequestProcessor.this.halt();
        }
    }
    ...
    private void halt() {
        stopped = true;
        wakeup();
        queuedRequests.clear();
        if (workerPool != null) { workerPool.stop(); }
    }
    ```

    The main `run()` loop's `while (!stopped)` (line 154) exits — hence `StagedRequestProcessor loop terminated` at line 191.

6. **The permanent silence — `StagedRequestProcessor.java:320-344`**

    ```java
    public void commit(Request request) {
        if (stopped || request == null) { return; }     // every commit dropped
        ...
    }
    public void processRequest(Request request) {
        if (stopped) { return; }                        // every request dropped
        ...
    }
    ```

    Ping requests, read requests, and commits are all silently discarded on that server.

7. **The client side timeout — `ClientCnxn.java:1150-1161`**

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

    With no ping response coming back (because #6 dropped it), `to` goes negative, the SendThread logs the "Session inactive – no server traffic for 6666ms" line at `ClientCnxn$SendThread@1207`, closes the socket, and any request that was on the wire completes to the caller as `KeeperException.ConnectionLoss`.

## Fix

Add `case OpCode.createExt: return true;` to `StagedRequestProcessor.needCommit()` alongside the other write opcodes. (Independently, `StageWorkRequest.cleanup()` shouldn't `halt()` the entire processor on a single downstream exception — one bad request currently takes the whole server's request pipeline offline.)
