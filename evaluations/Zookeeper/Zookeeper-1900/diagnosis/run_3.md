## Root cause

The observer restart resurrected a snapshot whose zxid is *ahead* of the just‑rebuilt leader:

- Its snap dir still holds `snapshot.100001013` (zxid `0x100001013`), so on start it loads that snapshot (`server_4.log` line 244148).
- Its txnlog dir was repointed at an empty replacement volume `.../txnlog-vol2` (line 244141) — **zero `log.*` files**.
- The rebuilt leader's max zxid is `0x10000023d` (line 244229), *lower* than the observer's.

Because the observer is ahead of the leader, the leader sends `TRUNC/ROLLBACK`, and the observer must truncate its own transaction log to the leader's zxid. But its log dir is empty, so the truncation code walks off a null stream and throws NPE. The NPE is not the `IOException` that `Observer.observeLeader` expects, so the socket it opened to the leader is never closed, and the observer immediately re‑elects and repeats — one orphaned socket per attempt.

## The exact branches that force the failure

1. **TRUNC/ROLLBACK arm taken in the learner sync** — `Learner.syncWithLeader`:
   - `src/java/main/org/apache/zookeeper/server/quorum/Learner.java:344` `else if (qp.getType() == Leader.ROLLBACK)` — chosen because the observer's zxid > leader's zxid.
   - `Learner.java:348` `boolean rolledBack = zk.getZKDatabase().rollBackLog(qp.getZxid());` — the call in the stack trace.

2. **Empty-log-dir path inside the iterator init** — `FileTxnLog$FileTxnIterator.init` uses the (empty) `logDir`:
   - `src/java/main/org/apache/zookeeper/server/persistence/FileTxnLog.java:568` `Util.sortDataDir(FileTxnLog.getLogFiles(logDir.listFiles(), 0), "log", false)` returns `[]`.
   - `FileTxnLog.java:569–578` the `for (File f : files)` loop adds nothing; `storedFiles` stays empty.
   - `FileTxnLog.java:579` `goToNextLog()` is called; at `FileTxnLog.java:602` the condition `if (storedFiles.size() > 0)` is **false**, so `createInputArchive` is skipped and the field `inputStream` (declared `null` at line 522) is **never assigned**.
   - `FileTxnLog.java:580` `if (!next()) return;` — `next()` returns immediately at `FileTxnLog.java:658` because `ia == null`.

3. **The NPE site** — `FileTxnLog.rollBack`:
   - `FileTxnLog.java:379` `itr = new FileTxnIterator(this.logDir, zxid);`
   - `FileTxnLog.java:380` `PositionInputStream input = itr.inputStream;` — `input` is `null`.
   - `FileTxnLog.java:381` `long pos = input.getPosition();` → **`NullPointerException`** — the exception in the stack trace.

4. **The socket-leak branch (why CLOSE_WAIT grows)** — `Observer.observeLeader` only handles `IOException`:
   - `src/java/main/org/apache/zookeeper/server/quorum/Observer.java:85` `catch (IOException e) { ... sock.close(); ... }` — `NullPointerException` is a `RuntimeException`, so this arm is skipped.
   - `Observer.java:88` `sock.close();` is therefore never executed on the failing iteration.
   - The finally at `Observer.java:96–98` only unregisters JMX; the leader-facing `sock` is never touched.

5. **Restart loop + shutdown that also omits `sock.close()`**:
   - `src/java/main/org/apache/zookeeper/server/quorum/QuorumPeer.java:962` catches the NPE from `observer.observeLeader()`.
   - `QuorumPeer.java:965` `observer.shutdown()` in the finally chains through `Observer.shutdown` (Observer.java:163) to `Learner.shutdown` at `src/java/main/org/apache/zookeeper/server/quorum/Learner.java:581`, which closes only `self.cnxnFactory` and `zk` — **it never closes `sock`**.
   - `QuorumPeer.java:967` `updateServerState()` puts the peer back to `LOOKING`; the switch re‑enters `OBSERVING`, a fresh `Observer` opens a fresh `sock`, and the whole path repeats — many times per second — orphaning one leader-facing socket per attempt, which ends up in CLOSE_WAIT once the leader tears its side down. Because `syncWithLeader` never returns cleanly, `ObserverZooKeeperServer` never begins serving, so the client port answers `srvr`/`ruok` but hands out no sessions.

The proximate defect is the `Leader.ROLLBACK` branch calling `rollBack` on an empty log dir; the amplifier that turns a single failure into an unbounded CLOSE_WAIT leak is `Observer.observeLeader`'s `catch (IOException)` (line 85) not covering the `RuntimeException` thrown from `rollBack`, combined with `Learner.shutdown` not closing `sock`.
