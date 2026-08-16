## Root cause

The leader tells member 4 to **rewind its transaction log to zxid `0x10000023d`** (see log line 3946599: `Rewinding the transaction journal to match the leader 0x10000023d`). Member 4 has no on-disk txn whose zxid is ≥ that value, and this uncovers a NPE in the rollback path. The relevant call chain is:

`EnsembleMember.run` → `ObserverPeer.observeLeader` → `PeerSynchronizer.syncWithLeader` (the `case Leader.ROLLBACK` branch, `PeerSynchronizer.java:344–354`) → `ZKStateStore.rollBackLog` (`ZKStateStore.java:500–512`) → `JournalSnapStore.rollBackLog` (`JournalSnapStore.java:311–328`) → `TxnJournal.rollBack` (`TxnJournal.java:376–395`).

### The exact fault

`TxnJournal.rollBack(zxid)`:

```java
376: public boolean rollBack(long zxid) throws IOException {
377:     TxnJournalIterator itr = null;
378:     try {
379:         itr = new TxnJournalIterator(this.logDir, zxid);
380:         PositionInputStream input = itr.inputStream;
381:         long pos = input.getPosition();   // <-- NPE here
```

The code assumes `itr.inputStream != null` after construction. It isn't, because of what happens inside the iterator's *fast-forward* loop:

```java
537: public TxnJournalIterator(File logDir, long zxid, boolean fastForward) ... {
541:     init();                              // opens the last log whose starting zxid < zxid,
                                              // sets inputStream, reads the first record via next()
543:     if (fastForward && hdr != null) {
544:         while (hdr.getZxid() < zxid) {
545:             if (!next()) break;
546:         }
547:     }
548: }
```

Since the rollback target `0x10000023d` is greater than every zxid on disk, `next()` keeps advancing until it hits the end of the last file and enters its EOF branch:

```java
678: } catch (EOFException e) {
679:     LOG.debug("EOF excepton " + e);
680:     inputStream.close();
681:     inputStream = null;         // <-- stream nulled
682:     ia = null;
683:     hdr = null;
684:     ...
686:     if (!goToNextLog()) {       // <-- storedFiles is empty → returns false
687:         return false;
688:     }
```

`goToNextLog()` at lines 601–608 returns false because `storedFiles` was drained by `init()` (it only ever held the single last file whose zxid < requested). `next()` returns false, the fast-forward `while` loop breaks (line 545), and the constructor returns with `inputStream == null`. Back in `rollBack()`, line 381 dereferences it → **`NullPointerException`**.

### Why the peer never recovers instead of exiting

`rollBack()` has only a `finally { close(itr); }`—no catch—so the NPE propagates up. In `PeerSynchronizer.syncWithLeader`:

```java
348: boolean rolledBack = zk.getZKStateStore().rollBackLog(qp.getZxid());
349: if (!rolledBack) {
350:     LOG.error("Unable to rewind the transaction journal " + ...);
353:     System.exit(13);              // <-- would kill the JVM, forcing a clean re-sync
354: }
```

Because rollback throws an NPE instead of returning `false`, the `System.exit(13)` self-healing path is never taken. The exception bubbles all the way to `EnsembleMember.run:961–963` which logs `"Unhandled error in the peer state machine"`, the peer loop restarts, tries to sync again, receives another `ROLLBACK` for the same zxid, and NPEs again forever—hence the endless repetition in the log and the member never serving clients.

### Determinative branches

1. `PeerSynchronizer.syncWithLeader` line 344 — `qp.getType() == Leader.ROLLBACK` (leader asks this observer to rewind).
2. `TxnJournalIterator.init` lines 569–577 — builds `storedFiles` containing only files whose starting zxid ≤ requested zxid; with the requested zxid ahead of everything on disk, at most one file is loaded.
3. `TxnJournalIterator` constructor lines 543–547 — `fastForward && hdr != null` is true, so the loop runs.
4. `TxnJournalIterator.next` lines 678–688 — the EOF branch nulls `inputStream` and then `goToNextLog()` returns false because `storedFiles` is empty.
5. `TxnJournal.rollBack` lines 380–381 — unconditional dereference of `itr.inputStream` → NPE.

### Fix locus

Either (a) guard line 381 (e.g., early-return `true` when `itr.inputStream == null`, meaning there's nothing left to rewind), or (b) don't null out `inputStream` in `next()`'s EOF branch until after a successful `goToNextLog()`, or (c) wrap the NPE/IOException in `PeerSynchronizer` so the peer takes the `System.exit(13)` recovery branch instead of looping forever.
