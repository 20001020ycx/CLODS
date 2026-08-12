## Root cause

The Observer (myid=4) is told by the leader (myid=3) to roll its transaction log back to zxid `0x10000023d` (see leader log line 137842: `Sending ROLLBACK to follower zxidToSend=0x10000023d for peer sid:4`). The rollback path throws NPE because `FileTxnLog.rollBack` dereferences an iterator whose `inputStream` is still `null`.

### Failure path (top → bottom of the stack)

1. **`Learner.syncWithLeader` — Learner.java:344‑354.** The `ROLLBACK` branch fires:
   ```java
   } else if (qp.getType() == Leader.ROLLBACK) {
       ...
       boolean rolledBack = zk.getZKDatabase().rollBackLog(qp.getZxid());   // line 348
   ```
2. **`ZKDatabase.rollBackLog` — ZKDatabase.java:500‑504** calls `snapLog.rollBackLog(zxid)`.
3. **`FileTxnSnapLog.rollBackLog` — FileTxnSnapLog.java:311‑317** builds a fresh `FileTxnLog` on `dataDir` and calls `rbLog.rollBack(zxid)`.
4. **`FileTxnLog.rollBack` — FileTxnLog.java:376‑395** — the actual crash site:
   ```java
   public boolean rollBack(long zxid) throws IOException {
       FileTxnIterator itr = null;
       try {
           itr = new FileTxnIterator(this.logDir, zxid);      // line 379
           PositionInputStream input = itr.inputStream;       // line 380  ← null
           long pos = input.getPosition();                    // line 381  ← NPE
   ```
   `itr.inputStream` is dereferenced with no null check.

### Why `itr.inputStream` is `null`

Inside `FileTxnIterator.init()` (FileTxnLog.java:566‑582):

```java
void init() throws IOException {
    storedFiles = new ArrayList<File>();
    List<File> files = Util.sortDataDir(FileTxnLog.getLogFiles(logDir.listFiles(), 0), "log", false);
    for (File f: files) {
        if (Util.getZxidFromName(f.getName(), "log") >= zxid) { storedFiles.add(f); }
        else if (Util.getZxidFromName(f.getName(), "log") <  zxid) { storedFiles.add(f); break; }
    }
    goToNextLog();
    if (!next()) return;
}
```

`goToNextLog()` (FileTxnLog.java:601‑608) only opens a stream when the list is non‑empty:

```java
private boolean goToNextLog() throws IOException {
    if (storedFiles.size() > 0) {                 // ← false in the failing case
        this.logFile = storedFiles.remove(storedFiles.size()-1);
        ia = createInputArchive(this.logFile);    // this is what would set inputStream
        return true;
    }
    return false;                                 // returns here → inputStream stays null
}
```

`createInputArchive()` (FileTxnLog.java:633‑642) is the only place that assigns `inputStream`, and it is never reached. `next()` (line 657) then short‑circuits at

```java
if (ia == null) { return false; }
```

so the constructor completes with `inputStream == null` and no exception. Control returns to `rollBack` which blindly reads `itr.inputStream.getPosition()` → **NullPointerException**.

The condition that empties `storedFiles` on Observer #4 is that **the observer’s `dataLogDir` contains no txn‑log file with a first‑zxid ≤ `0x10000023d`** (in this run there are no local log files at all — this ensemble has just come up and the Observer’s only prior sync attempt was the SNAP at 18:09:28, which was aborted; there was never a txn log written to disk). With `files` empty the `for` loop never adds anything to `storedFiles`, so both branches of

```java
if (Util.getZxidFromName(f.getName(), "log") >= zxid) …
else if (Util.getZxidFromName(f.getName(), "log") <  zxid) …
```
are simply never taken.

### Why it repeats thousands of times

`QuorumPeer.run` — QuorumPeer.java:957‑968 — catches the NPE at the `OBSERVING` case, logs `"Unexpected exception"`, resets state, and loops right back to `observeLeader()`:

```java
case OBSERVING:
    try {
        setObserver(makeObserver(logFactory));
        observer.observeLeader();                 // line 961 (frame in stack)
    } catch (Exception e) {
        LOG.warn("Unexpected exception", e);      // line 963 – the WARN in the log
    } finally { observer.shutdown(); setObserver(null); updateServerState(); }
    break;
```

Because the underlying condition (no matching txn‑log file for the leader’s rollback zxid) is not repaired between iterations, every reconnect ends in the same NPE — hence the identical WARN repeating on tight loop, and the node never begins serving clients.

### One‑line fix locus

Guard against the empty‑iterator case in `FileTxnLog.rollBack` (line 381) — e.g., treat `itr.inputStream == null` (equivalently `storedFiles` empty / `logFile == null`) as “nothing to truncate” and return `true` without calling `input.getPosition()`. Equivalently, `FileTxnIterator.init()` at line 579 should not silently leave the iterator in a half‑constructed state when `storedFiles` is empty.
