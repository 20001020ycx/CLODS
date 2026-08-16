## Root Cause

Observer `myid=4` was restarted with a different `dataDir` (transaction-log directory) than it had on its first run, while its `dataLogDir`/snap dir stayed the same:

- Original run (18:44:34, `logs/symptom.log:1785789`):
  `datadir=/tmp/zk-repro-wHT9/hosts/zk4/txnlog`, `snapDir=/tmp/zk-repro-wHT9/hosts/zk4/data`
- After shutdown at 19:02:05 and restart at 19:06:24 (`logs/symptom.log:3944650`):
  `datadir=/tmp/zk-repro-wHT9/hosts/zk4/txnlog-vol2`, `snapDir=/tmp/zk-repro-wHT9/hosts/zk4/data`

The snapshot in `data/version-2/` is still there from the previous run (loaded on startup), so the peer reports a non-zero last-processed zxid to the leader. But the newly-configured txnlog directory `txnlog-vol2/version-2/` contains **no `log.*` files at all** — the log volume is fresh/empty.

The leader responds to zk4's sync with `Leader.ROLLBACK` to zxid `0x10000023d` (`logs/symptom.log:3946599`, `PeerSynchronizer.syncWithLeader:344–348`), which calls `zk.getZKStateStore().rollBackLog(qp.getZxid())` → `JournalSnapStore.rollBackLog:317` → `TxnJournal.rollBack:376`. That function blindly dereferences the iterator's input stream, and there is no code path to handle "no log files present" — hence the NPE.

## Exact failing path

`TxnJournal.rollBack(long zxid)` (`source/src/java/main/org/apache/zookeeper/server/persistence/TxnJournal.java:376`):

```java
itr = new TxnJournalIterator(this.logDir, zxid);       // line 379
PositionInputStream input = itr.inputStream;           // line 380
long pos = input.getPosition();                        // line 381  <-- NPE
```

`itr.inputStream` is `null` because the constructor chain never opened any file. The exact branches that leave it null, given an empty `txnlog-vol2/version-2/`:

1. `TxnJournalIterator(logDir, zxid)` (line 557) → delegates to `TxnJournalIterator(logDir, zxid, true)` (line 537) → `init()` (line 566).
2. `init()` at line 568:
   ```java
   List<File> files = Util.sortDataDir(TxnJournal.getLogFiles(logDir.listFiles(), 0), "log", false);
   ```
   `logDir.listFiles()` for the fresh `txnlog-vol2/version-2/` contains no `log.*` files, so `getLogFiles(...)` returns an empty array → `files` is empty. The `for (File f : files)` loop at lines 569–578 never runs; **`storedFiles` remains empty**.
3. `goToNextLog()` (line 601–608):
   ```java
   if (storedFiles.size() > 0) {                       // false — branch NOT taken
       this.logFile = storedFiles.remove(storedFiles.size()-1);
       ia = createInputArchive(this.logFile);          // never called
       return true;
   }
   return false;                                       // taken
   ```
   Because `createInputArchive(...)` is never invoked, the `if (inputStream == null)` block at line 634–640 that assigns `inputStream = new PositionInputStream(...)` never runs. **`inputStream` stays at its declared default `null`** (line 522), and `ia` stays `null`.
4. Back in `init()` line 580: `if (!next()) return;`
   `next()` (line 657) takes the `if (ia == null) return false;` branch at lines 658–660 and returns `false` immediately — so `init()` returns cleanly with `inputStream == null`, `hdr == null`, `ia == null`.
5. Back in the constructor at line 543: `if (fastForward && hdr != null)` is `false` (hdr is null), so nothing else runs. The constructor returns an "empty" iterator with `inputStream == null`.
6. Control returns to `TxnJournal.rollBack` at line 380–381: `input = itr.inputStream` is `null`, and `input.getPosition()` throws `NullPointerException`.

The exception propagates:
- `TxnJournal.rollBack:381` → `JournalSnapStore.rollBackLog:317` (`boolean rolledBack = rbLog.rollBack(zxid);`)
- → `ZKStateStore.rollBackLog:504` (`boolean rolledBack = snapLog.rollBackLog(zxid);`)
- → `PeerSynchronizer.syncWithLeader:348` (`boolean rolledBack = zk.getZKStateStore().rollBackLog(qp.getZxid());`)
- → `ObserverPeer.observeLeader:79`
- → `EnsembleMember.run:961` — caught by the top-level state-machine handler that logs *"Unhandled error in the peer state machine"* at line 963 (`logs/symptom.log:3946643`).

The observer then does `role shutdown requested` and immediately restarts into the same OBSERVING → sync → ROLLBACK → NPE loop (visible from 19:06:27 onward for every subsequent attempt), so it never begins serving client requests.

## Summary of the defect

`TxnJournal.rollBack` (`TxnJournal.java:376–395`) assumes `TxnJournalIterator.init()` always opens at least one log file. Two conditions can violate that assumption:
- `storedFiles.size() == 0` after the loop at lines 569–578 (as here: empty `logDir`), so `goToNextLog()` at line 579 takes its `return false` branch.
- Or `init()` opened a file but `next()` immediately EOFs and `goToNextLog()` returns false at line 686, leaving `inputStream = null` via the EOF handler at lines 680–681.

In either case, `input.getPosition()` at line 381 dereferences `null`. The trigger in this run is the first: the operator (or start script) restarted zk4 with a different `dataDir` (`txnlog` → `txnlog-vol2`) but kept the old `snapDir`, so the peer has snapshot state (non-zero last-processed zxid → leader picks ROLLBACK over DIFF/SNAP) but zero transaction-log files, and `TxnJournal.rollBack` has no null-guard for that case.
