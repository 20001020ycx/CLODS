## Root cause

`FileTxnLog.rollBack(long zxid)` at `source/src/java/main/org/apache/zookeeper/server/persistence/FileTxnLog.java:381` unconditionally dereferences `itr.inputStream` — but `FileTxnIterator` legitimately leaves that field `null` when there is nothing in the log directory to seek to. On this observer (myid=4), the configured txnlog directory (`/tmp/zk-repro-tPiT/hosts/zk4/txnlog-vol2/version-2`, line 244226) contains no `log.*` files that reach the rollback target `0x10000023d` (line 244229), so the very first `input.getPosition()` in `rollBack` NPEs. `QuorumPeer.run` at `QuorumPeer.java:961–963` catches the exception, tears the observer down, re-enters `OBSERVING`, and the same rollback attempt repeats forever.

## The exact failure path

1. `Learner.syncWithLeader` at `Learner.java:344–348` — the leader sent `Leader.ROLLBACK`, so the code takes that `else if` branch and calls `zk.getZKDatabase().rollBackLog(qp.getZxid())` with `zxid = 0x10000023d`.
2. `FileTxnSnapLog.rollBackLog` at `FileTxnSnapLog.java:311–317` closes the current log and calls `new FileTxnLog(dataDir).rollBack(zxid)`.
3. `FileTxnLog.rollBack` at `FileTxnLog.java:376–395` constructs `itr = new FileTxnIterator(this.logDir, zxid)` (the 2-arg ctor at line 557 delegates with `fastForward=true`), then unconditionally does:
   ```java
   PositionInputStream input = itr.inputStream;   // line 380
   long pos = input.getPosition();                 // line 381 → NPE
   ```
   There is no `null` guard on `itr.inputStream`, and no branch that would create the stream after the iterator has been constructed.
4. `FileTxnIterator.inputStream` is declared `null` at line 522. The **only** code path that assigns it is `createInputArchive` at lines 633–642, and that path is reached only from `goToNextLog` at line 604.
5. `FileTxnIterator.init` at lines 566–582 populates `storedFiles` from `Util.sortDataDir(getLogFiles(logDir.listFiles(), 0), "log", false)`. For this observer the txnlog directory is effectively empty (no `log.*` files with a zxid at/below the rollback target), so `storedFiles` ends up empty (or containing only files whose txns all sit below the target zxid).
6. `goToNextLog` at lines 601–608 takes the `if (storedFiles.size() > 0)` **false** branch and returns `false` without ever calling `createInputArchive` — so `inputStream` stays `null`.
7. `next()` at lines 657–660 then returns via the `if (ia == null) return false;` branch (line 658), so `init()` returns with `hdr == null`.
8. Back in the `FileTxnIterator(File, long, boolean)` constructor at lines 543–548, the `if (fastForward && hdr != null)` guard is **false**, so the fast-forward loop is skipped — nothing else can populate `inputStream`.
9. Control returns to `rollBack` and line 381 dereferences the `null` field.

(There is a second, equivalent way to reach the same NPE: if `storedFiles` did contain one file below `zxid`, `next()` would iterate it to EOF during fast-forward, hit the `catch (EOFException)` block at lines 678–690 which does `inputStream.close(); inputStream = null; ia = null; hdr = null;`, then call `goToNextLog()` which returns `false` because there are no more files — leaving `inputStream` `null` in exactly the same way. Either branch produces the observed stack.)

## Fix in one line

`FileTxnLog.rollBack` must handle the "iterator has no open stream" case — e.g. `if (itr.inputStream == null) return true;` before line 380 — instead of blindly dereferencing `itr.inputStream.getPosition()`. Since `QuorumPeer.run` swallows the exception and immediately re-enters `OBSERVING`, this bug is what produces the "thousands of times" repetition the user observed.
