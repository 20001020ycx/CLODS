## Root cause

The NPE is thrown at `FileTxnLog.java:381` inside `rollBack(long zxid)`:

```java
public boolean rollBack(long zxid) throws IOException {
    FileTxnIterator itr = null;
    try {
        itr = new FileTxnIterator(this.logDir, zxid);   // line 379
        PositionInputStream input = itr.inputStream;     // line 380
        long pos = input.getPosition();                  // line 381  <-- NPE
        ...
```

`itr.inputStream` is `null`. `rollBack` unconditionally dereferences it without checking, so whenever the iterator ends construction with `inputStream == null`, this line throws.

## How `inputStream` becomes null

The 2-arg constructor (`FileTxnLog.java:557-559`) calls the fastForward=true constructor. Its logic:

```java
public FileTxnIterator(File logDir, long zxid, boolean fastForward) ... {
    ...
    init();                                              // line 541
    if (fastForward && hdr != null) {                    // line 543
        while (hdr.getZxid() < zxid) {
            if (!next()) break;
        }
    }
}
```

Inside `init()` (line 566) and `next()` (line 657), the stream is closed and nulled on the EOF path:

```java
} catch (EOFException e) {
    inputStream.close();
    inputStream = null;                                  // line 681
    ia = null;
    hdr = null;
    if (!goToNextLog()) {                                // line 686
        return false;
    }
    return next();
}
```

`goToNextLog()` (line 601) only re-creates the input archive when there is still an unconsumed file in `storedFiles`; if the list is empty it just returns `false` — it never resets `inputStream`. So after `next()` returns `false` on EOF-with-no-more-logs, we have `inputStream == null` and `hdr == null`. The constructor's fastForward loop is guarded by `hdr != null`, so it silently exits with a fully-null iterator, and control returns to `rollBack`, which then dereferences `itr.inputStream`.

## The branches that reach this state in this run

Stack: `Observer.observeLeader → Learner.syncWithLeader`. In `Learner.java:344-354`, the leader's packet type is `Leader.ROLLBACK`, so:

```java
} else if (qp.getType() == Leader.ROLLBACK) {
    ...
    boolean rolledBack = zk.getZKDatabase().rollBackLog(qp.getZxid());   // line 348
```

That flows into `ZKDatabase.rollBackLog:504 → FileTxnSnapLog.rollBackLog:317 → FileTxnLog.rollBack`. So the leader has told observer `myid=4` to roll its transaction log back to zxid `qp.getZxid()`. Once `rollBack` starts, the iterator ends up empty because one of these three branches in `init()` holds:

1. **No log files at all** — `Util.sortDataDir(getLogFiles(...))` returns an empty list, so `storedFiles` is empty, `goToNextLog()` at line 579 returns `false`, `ia` stays `null`, and `next()` at 580 immediately returns `false` (branch `if (ia == null) return false;` at line 658).
2. **First log file is empty / preallocated only** — `goToNextLog()` opens the file (setting `inputStream` at line 635), `next()` reads past the header, `Util.readTxnBytes` returns null/zero-length, `next()` throws `EOFException` at line 666 → catches at 678, nulls `inputStream`, calls `goToNextLog()` which returns `false` because `storedFiles` is exhausted.
3. **fastForward exhausts every txn without meeting the target** — repeated calls to `next()` walk past every transaction; the last one hits EOF, executes the catch at 678-682 (nulling `inputStream`, `ia`, `hdr`), and `goToNextLog()` returns `false`.

For an observer receiving ROLLBACK, the leader's `qp.getZxid()` is less than the observer's committed high‑water mark, but the observer's on-disk `log.*` files here either don't exist, are empty, or the fastForward walk exhausts them without landing on a transaction. Any of those paths leave `inputStream == null` at the moment `rollBack` runs line 381.

## Why the WARN repeats forever

`QuorumPeer.run` at line 961 wraps the state-machine loop in a broad `catch (Exception e)` that logs "Unexpected exception" (this is exactly what appears in `symptom.log`). The exception is swallowed, the OBSERVING state is re-entered, `observeLeader` re-connects, the leader again detects the observer is ahead and sends `Leader.ROLLBACK`, and the same NPE is thrown — thousands of times.

## The concrete defect

`FileTxnLog.rollBack` at line 381 must handle the documented post-condition of `FileTxnIterator` where `inputStream` is `null` (either because there are no eligible log files, or because the fastForward consumed the tail and hit `EOFException` in `next()` at lines 678-687). Without a `null` check — or without `goToNextLog()`/`init()` guaranteeing a live `inputStream` when `storedFiles` is empty — every observer rollback whose target zxid falls past the end of the local txnlog crashes here.
