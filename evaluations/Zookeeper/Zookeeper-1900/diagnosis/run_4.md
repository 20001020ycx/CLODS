## Root cause

The restarted zk4 process (started at 19:06:23) is configured with a **different transaction-log directory** than its snapshot directory:

```
[myid:4] JournalSnapStore@84 - Opening datadir:/tmp/zk-repro-wHT9/hosts/zk4/txnlog-vol2 snapDir:/tmp/zk-repro-wHT9/hosts/zk4/data
```

The old runs used `.../hosts/zk4/txnlog`. The restart's `dataLogDir` is `txnlog-vol2` (empty), while `dataDir` (`.../hosts/zk4/data`) still contains the pre-existing snapshots (it loads `snapshot.100000f3e`). So on this observer, the txnlog dir has **zero** `log.*` files. When the leader then tells zk4 to `ROLLBACK` to `0x10000023d` (logged at 19:06:27,386), the code walks straight into an unguarded null-deref.

## The exact failure path

`PeerSynchronizer.syncWithLeader` receives a `Leader.ROLLBACK` packet and takes the `else if` branch:

- `PeerSynchronizer.java:344-348` — `qp.getType() == Leader.ROLLBACK` is true, so it calls `zk.getZKStateStore().rollBackLog(qp.getZxid())` with `qp.getZxid() = 0x10000023d`.
- `ZKStateStore.java:500-504` — clears in-memory state and calls `snapLog.rollBackLog(zxid)`.
- `JournalSnapStore.java:311-317` — constructs `new TxnJournal(dataDir)` where `dataDir = /tmp/zk-repro-wHT9/hosts/zk4/txnlog-vol2/version-2` and calls `rbLog.rollBack(0x10000023d)`.
- `TxnJournal.java:376-395` (`rollBack`) — constructs `new TxnJournalIterator(this.logDir, zxid)`.

Inside the iterator (`TxnJournal.java:513-608`), on an empty log directory:

1. `TxnJournalIterator(logDir, zxid)` → `this(logDir, zxid, true)` (line 557-559) → `init()` (line 541).
2. `init()` line 568: `Util.sortDataDir(TxnJournal.getLogFiles(logDir.listFiles(), 0), "log", false)` returns an empty list — no `log.*` files exist in `txnlog-vol2/version-2`.
3. The `for (File f : files)` loop (lines 569-578) iterates zero times, so `storedFiles` stays empty.
4. `goToNextLog()` (lines 601-608): the branch `if (storedFiles.size() > 0)` is **false**, so it returns `false` without ever assigning `logFile`, without calling `createInputArchive`, and — critically — leaving `inputStream` at its declared default of `null` (line 522: `PositionInputStream inputStream = null;`).
5. `init()` then calls `next()` (line 580). In `next()` (line 657) the branch `if (ia == null) return false;` (lines 658-660) is taken, because `goToNextLog` never set `ia` either. `init()` returns.
6. Back in the constructor, the fast-forward guard `if (fastForward && hdr != null)` (line 543) is **false** because `hdr` is still `null` — so the fast-forward loop is a no-op. The constructor exits with `inputStream == null`.
7. Back in `rollBack()`:
   - line 380: `PositionInputStream input = itr.inputStream;` — assigns `null`.
   - line 381: `long pos = input.getPosition();` — **NullPointerException**.

Every branch is dictated by `storedFiles` being empty because `logDir.listFiles()` has no `log.*` files, which in turn is caused by the operator/config splitting `dataLogDir` off to a fresh volume (`txnlog-vol2`) while leaving `dataDir` pointing at the old snapshot volume. The stack unwinds through `ObserverPeer.observeLeader` (line 79), which is inside `EnsembleMember.run` (line 961), and `EnsembleMember@963` logs the `WARN` — so the ObserverPeer thread aborts on every reconnect attempt and zk4 never serves clients.

The underlying code defect is that `TxnJournal.rollBack` (line 380-381) assumes `itr.inputStream` is non-null even though `TxnJournalIterator.init()` legitimately leaves it null whenever the log directory has no `log.*` files (or whenever fast-forward runs off the end of the last file).
