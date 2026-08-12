## Root Cause

The observer (myid=4) receives a `Leader.ROLLBACK` packet, which calls down through `Learner.syncWithLeader` → `ZKDatabase.rollBackLog` → `FileTxnSnapLog.rollBackLog` → `FileTxnLog.rollBack(zxid)`. The NPE fires on the first executable line of that method:

**`FileTxnLog.java:380–381`**
```java
itr = new FileTxnIterator(this.logDir, zxid);
PositionInputStream input = itr.inputStream;   // may be null
long pos = input.getPosition();                // <-- NPE here (line 381)
```

`rollBack()` unconditionally dereferences `itr.inputStream`, but the `FileTxnIterator` it just constructed is allowed to leave `inputStream == null`. `inputStream` is declared null at `FileTxnLog.java:522` and is only set inside `createInputArchive()` (line 633‑642), which itself is only reached from `goToNextLog()` (line 601‑608) when `storedFiles.size() > 0`.

### The two branches that leave `inputStream == null`

Both live in `FileTxnIterator` (called from the `rollBack` path, which uses the two‑arg constructor at line 557, so `fastForward=true`):

1. **No matching log files.** In `init()` (line 566‑582):
   ```java
   goToNextLog();            // line 579 – returns false, does NOT set inputStream
   if (!next()) return;      // line 580‑581 – next() sees ia==null, returns false
   ```
   If `logDir.listFiles()` produces no `log.*` files (or none pass the two `if` conditions at lines 570 and 574), `storedFiles` is empty, `goToNextLog()` takes the `return false` branch at line 607, `createInputArchive` is never called, `inputStream` stays null, and `init()` returns silently. This is the situation for a fresh/empty‑`dataLogDir` observer that receives ROLLBACK from the leader.

2. **Fast‑forward consumes every txn.** In the constructor at lines 543‑548:
   ```java
   if (fastForward && hdr != null) {
       while (hdr.getZxid() < zxid) {
           if (!next()) break;
       }
   }
   ```
   When the loop pushes past the last transaction, `next()` (line 657‑696) hits `EOFException` and executes lines 678‑690:
   ```java
   inputStream.close();
   inputStream = null;     // <-- line 681
   ia = null;
   ...
   if (!goToNextLog()) {
       return false;       // no more log files -> leaves inputStream == null
   }
   ```
   If `goToNextLog()` returns false (no more files), the constructor returns with `inputStream == null`.

Either branch leaves the caller in `rollBack()` holding a null `input`, so `input.getPosition()` at **line 381** throws `NullPointerException`.

### Why it repeats forever

The exception propagates up to `QuorumPeer.run()` (line 963), which logs `"Unexpected exception"` and simply loops back to reconnect and observe the leader again. Nothing on disk changes between iterations (no txn log gets written), so the very same `FileTxnIterator` is reconstructed with the same empty/exhausted `storedFiles` set, and the very same NPE is thrown — thousands of times.

### Defect

The bug is in `FileTxnLog.rollBack` (line 376‑395): it assumes `FileTxnIterator` always produces an open stream. `FileTxnIterator`'s own contract (via `init()`/`next()`/`goToNextLog()`) explicitly permits `inputStream == null` when there is nothing to iterate. `rollBack` needs to check `itr.inputStream != null` (or equivalently that `storedFiles` had a usable file) before calling `getPosition()`/opening the `RandomAccessFile` — treating "no log to roll back" as a successful no‑op (return `true`) rather than dereferencing null.
