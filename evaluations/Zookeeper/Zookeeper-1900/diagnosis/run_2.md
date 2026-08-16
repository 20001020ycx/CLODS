## Root cause

The NPE at `TxnJournal.java:381` is a missing null-check on `TxnJournalIterator.inputStream`. The rollback path leaves the iterator in a state where `inputStream == null`, then dereferences it.

**The failure path — file/line and branches**

1. `PeerSynchronizer.syncWithLeader` (`PeerSynchronizer.java:344-348`): the observer (myid=4) receives a `Leader.ROLLBACK` packet from the leader and calls
   ```java
   zk.getZKStateStore().rollBackLog(qp.getZxid());   // line 348
   ```
   This walks through `ZKStateStore.rollBackLog:504` → `JournalSnapStore.rollBackLog:317` → `TxnJournal.rollBack`.

2. `TxnJournal.rollBack(long zxid)` (`TxnJournal.java:376-395`):
   ```java
   itr = new TxnJournalIterator(this.logDir, zxid);   // 379  (fastForward = true)
   PositionInputStream input = itr.inputStream;       // 380  ← no null check
   long pos = input.getPosition();                    // 381  ← NPE
   ```

3. Why `itr.inputStream` is null when the constructor returns. `TxnJournalIterator(logDir, zxid)` → `this(logDir, zxid, true)` (line 558), which runs `init()` (line 566-582), then a fast-forward loop (lines 543-548):

   ```java
   goToNextLog();               // 579
   if (!next()) return;         // 580-581  ← silent return

   if (fastForward && hdr != null) {   // 543
       while (hdr.getZxid() < zxid) {  // 544
           if (!next()) break;         // 545-546
       }
   }
   ```

   Two branch combinations reach the NPE. The one consistent with the log (myid=4 has a real log segment `log.100000001` — see line 1788380 of `symptom.log` — and the leader is at a much larger zxid) is:

   - `init()`'s `goToNextLog()` (line 601-608) takes the `storedFiles.size() > 0` branch, opens the sole segment via `createInputArchive` (line 633-642), so `inputStream` is created.
   - The initial `next()` at line 580 succeeds; `init()` returns.
   - The fast-forward `while (hdr.getZxid() < zxid)` loop (line 544) keeps calling `next()` because every locally-known zxid is smaller than the leader's rollback zxid.
   - Eventually `next()` reads past the last record. At line 665 the branch `if (bytes == null || bytes.length == 0)` fires and throws `EOFException` (line 666).
   - The `catch (EOFException)` at line 678-687 runs:
     ```java
     inputStream.close();
     inputStream = null;      // 681  ← this is what makes rollBack NPE
     ia = null;
     hdr = null;
     if (!goToNextLog()) return false;   // 686-687
     ```
     Since `storedFiles` is now empty, `goToNextLog()` takes the false branch at line 602 (`storedFiles.size() > 0` is false) and returns false; `next()` returns false, the fast-forward `while` breaks with `hdr == null` and `inputStream == null`.

   (The second, symmetric branch — an empty `storedFiles` after `init`'s for-loop at lines 569-577, or a preallocated but empty log segment — reaches the same state; the direct cause is the same missing null-check.)

4. Control returns to `TxnJournal.rollBack:380`. `itr.inputStream` is now `null`; line 381 invokes `input.getPosition()` → `NullPointerException`, which propagates out through `JournalSnapStore.rollBackLog:317`, `ZKStateStore.rollBackLog:504`, `PeerSynchronizer.syncWithLeader:348` and is caught as the "Unhandled error in the peer state machine" in `EnsembleMember.run:961/963`. On every re-attempt the observer receives the same `ROLLBACK` packet and repeats the crash, so myid=4 never advances into serving client requests.

**Specific offending logic**

- `TxnJournal.java:380-381` — dereferences `itr.inputStream` without checking `!= null` (and without checking that `itr.hdr`/`ia` are valid, which would indicate the iterator actually opened a segment).
- `TxnJournal.java:681` — `next()`'s EOF handler nulls `inputStream` but leaves the iterator in a superficially valid state.
- `TxnJournal.java:580` — `init()`'s `if (!next()) return;` silently swallows the empty-iterator case, so callers can't tell that no segment is really open.
- `TxnJournalIterator.goToNextLog` line 602 branch `storedFiles.size() > 0 == false` is the condition that ultimately prevents `inputStream` from being repopulated after the EOF path.

Fix: in `TxnJournal.rollBack`, gate the position/truncate work on `itr.inputStream != null` (equivalently, on the iterator having successfully opened a log segment covering `zxid`); on the empty/exhausted path there is nothing to truncate and rollback should be a no-op returning `true`.
