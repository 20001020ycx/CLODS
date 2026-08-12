## Root cause

The observer machine kept its **snapshot directory** from the previous deployment (dataDir still contains `snapshot.100001013` from epoch 1) but its **transaction-log directory was pointed at a fresh empty volume**. On startup the observer loads the retained snapshot (server_4.log:244148 – `Reading snapshot .../snapshot.100001013`) so its `lastProcessedZxid` is `0x100001013`, but the freshly-provisioned leader is at `0x10000023d` — an epoch further along but a *smaller* absolute zxid. The leader therefore replies with `ROLLBACK`, and the rollback code cannot cope with an empty txn-log directory.

## The exact code path

1. **Observer main loop** — `QuorumPeer.run` in the `OBSERVING` branch:
   - `QuorumPeer.java:960-968` — `setObserver(...); observer.observeLeader();` inside a `try { ... } catch (Exception e) { LOG.warn("Unexpected exception",e); } finally { observer.shutdown(); ... updateServerState(); }`. Because *any* `Exception` is caught, the peer never dies; it just loops back through LOOKING and re-enters OBSERVING.

2. **Connect + sync** — `Observer.observeLeader` at `Observer.java:67-99`:
   - line 74 `connectToLeader(addr)` — opens a new `Socket` (see `Learner.connectToLeader` at `Learner.java:228`, `sock = new Socket()`).
   - line 79 `syncWithLeader(newLeaderZxid)` — throws `NullPointerException`.
   - The `catch` on line 85 catches **only `IOException`**, so the NPE propagates past the `sock.close()` on line 88.
   - The `finally` on line 96 just calls `zk.unregisterJMX(this)`; it does **not** close `sock`.

3. **Sync branch selection** — `Learner.syncWithLeader` at `Learner.java:320-356`:
   - The leader sent `Leader.ROLLBACK` (because the observer's `lastLoggedZxid` in `OBSERVERINFO` is ahead of the leader).
   - Branch `else if (qp.getType() == Leader.ROLLBACK)` (line 344) is taken, and line **348** calls `zk.getZKDatabase().rollBackLog(qp.getZxid())` — logged one line earlier as `Rolling back the transaction log to get in sync with the leader 0x10000023d` (server_4.log:244229).

4. **Rollback drills into the empty txn-log directory**:
   - `ZKDatabase.rollBackLog` (`ZKDatabase.java:500-512`) — line 504 `snapLog.rollBackLog(zxid)`.
   - `FileTxnSnapLog.rollBackLog` (`FileTxnSnapLog.java:311-317`) — line 316 constructs `new FileTxnLog(dataDir)` on the *empty* replacement volume; line 317 calls `rbLog.rollBack(zxid)`.

5. **The NPE** — `FileTxnLog.rollBack` (`FileTxnLog.java:376-395`):
   ```java
   itr   = new FileTxnIterator(this.logDir, zxid);   // line 379
   PositionInputStream input = itr.inputStream;      // line 380
   long pos = input.getPosition();                   // line 381  <-- NPE
   ```
   The reason `itr.inputStream` is null: `FileTxnIterator.init()` at `FileTxnLog.java:566-582`:
   ```java
   storedFiles = new ArrayList<File>();
   List<File> files = Util.sortDataDir(FileTxnLog.getLogFiles(logDir.listFiles(), 0), "log", false);
   for (File f: files) { ... }        // logDir is empty  ->  loop body never runs
   goToNextLog();                     // line 579
   if (!next()) return;               // line 580
   ```
   With an empty `logDir`, `files` is empty, `storedFiles` stays empty, `goToNextLog()` at `FileTxnLog.java:601-608` takes the `storedFiles.size() > 0` branch as false and returns without ever touching `inputStream` (which is still null from its declaration on line 522 `PositionInputStream inputStream=null;`). Line 381 dereferences that null and throws the exception seen at server_4.log:244231-244238.

## Why the loop is infinite and why it makes no progress

Every iteration produces the same NPE, because nothing on the failure path ever **writes** a snapshot or otherwise brings `dataDir` into a self-consistent state — the snapshot-at-NEWLEADER logic in `Learner.syncWithLeader` (lines ~427-450 in the `Leader.NEWLEADER` branch) is **downstream** of line 348, so control never reaches it. Between iterations the observer just returns to `LOOKING`, re-elects, discovers leader 3, transitions to `OBSERVING`, re-reads `snapshot.100001013`, sends `OBSERVERINFO` with the same too-large zxid, gets another `ROLLBACK`, and NPEs again — exactly the pattern in the log (state cycles LOOKING → OBSERVING → NPE repeatedly with `n.round` incrementing).

## Why sockets pile up in CLOSE_WAIT

Two branches co-operate to leak the connection:

- **`Observer.observeLeader:85`** — the `catch (IOException e)` closes `sock`. Because the thrown exception is `NullPointerException`, this branch is skipped.
- **`Learner.shutdown` (`Learner.java:581-590`)** — invoked from the `finally` block of `QuorumPeer.run` case OBSERVING via `Observer.shutdown` (`Observer.java:163-166`, which just calls `super.shutdown()`). It closes the client-facing cnxnFactory and calls `zk.shutdown()`, but it never calls `sock.close()` on the learner→leader TCP socket.

So each failed attempt allocates a fresh `Socket` in `Learner.connectToLeader:228`/`242` and abandons the previous one with no reference held by the process (the file descriptor persists inside the JVM's socket wrapper until GC). The leader's side eventually reacts to the aborted sync by shutting its half of the pipe, sending FIN — but the observer never `read()`s the EOF or `close()`s its half, so the kernel parks each socket in **CLOSE_WAIT** for as long as the JVM holds the FD. One extra CLOSE_WAIT per election round matches the observed monotonic growth.

## Summary of the decisive conditions

| # | Location | Condition that must hold |
|---|---|---|
| 1 | Observer's on-disk state | `dataDir` retains snapshots from the old ensemble; `dataLogDir` is a brand-new empty volume |
| 2 | `Learner.syncWithLeader` | `qp.getType() == Leader.ROLLBACK` (line 344) — leader chose ROLLBACK because observer's `lastLoggedZxid` from the stale snapshot > leader's zxid |
| 3 | `FileTxnLog$FileTxnIterator.init` | Log directory has **zero** log files → `storedFiles` empty → `goToNextLog()` returns false → `inputStream` stays `null` |
| 4 | `FileTxnLog.rollBack:381` | `input.getPosition()` on that null stream → `NullPointerException` |
| 5 | `Observer.observeLeader:85` | `catch (IOException e)` — an NPE is **not** an IOException, so the `sock.close()` on line 88 is skipped |
| 6 | `Learner.shutdown:581-590` / `Observer.shutdown:163` | Neither closes `sock`, so the socket opened in `Learner.connectToLeader:228` leaks |
| 7 | `QuorumPeer.run:962` | Broad `catch (Exception e)` swallows the NPE and re-enters the state machine, guaranteeing the next OBSERVING attempt repeats the whole failure — with another leaked socket |
