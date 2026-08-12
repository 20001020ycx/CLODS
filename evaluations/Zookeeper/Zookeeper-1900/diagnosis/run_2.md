## Root cause

The observer's **snapshot directory** was preserved (it still holds `snapshot.100001013` from the previous deployment) but its **transaction-log directory** was swapped to a fresh empty volume. So on startup the observer loads a snapshot whose zxid `0x100001013` is *ahead* of the newly rebuilt leader's last zxid `0x10000023d` — but there are zero `log.*` files on the new txnlog volume.

The leader therefore sends `Leader.ROLLBACK`, and `FileTxnLog.rollBack` blows up on the empty directory because `FileTxnIterator` never opens an input stream. The resulting exception is a `NullPointerException`, which is *not* an `IOException`, so the one place that closes the leader socket is skipped and the socket is leaked. The peer falls back to LOOKING, re-elects, re-connects, and reproduces the same NPE forever.

Observed stack (server_4.log line 244231-244238):
```
java.lang.NullPointerException
    at FileTxnLog.rollBack(FileTxnLog.java:381)
    at FileTxnSnapLog.rollBackLog(FileTxnSnapLog.java:317)
    at ZKDatabase.rollBackLog(ZKDatabase.java:504)
    at Learner.syncWithLeader(Learner.java:348)
    at Observer.observeLeader(Observer.java:79)
    at QuorumPeer.run(QuorumPeer.java:961)
```

## Exact lines and branches that dictate the failure

**1. Leader picks the ROLLBACK branch — `Learner.syncWithLeader`, Learner.java:344-354**
```java
} else if (qp.getType() == Leader.ROLLBACK) {
    LOG.warn("Rolling back the transaction log ... 0x" + Long.toHexString(qp.getZxid()));
    boolean rolledBack = zk.getZKDatabase().rollBackLog(qp.getZxid());   // line 348
```
Taken because the observer's in-memory zxid loaded from `snapshot.100001013` is greater than `newLeaderZxid = 0x10000023d`.

**2. `FileTxnIterator.init()` finds no log files — FileTxnLog.java:566-582**
```java
List<File> files = Util.sortDataDir(FileTxnLog.getLogFiles(logDir.listFiles(), 0), "log", false);
for (File f: files) { ... }        // loop body never executes — dir is empty
goToNextLog();                     // returns false
if (!next()) return;
```
Because the new `txnlog-vol2` volume contains no `log.*`, `storedFiles` stays empty.

**3. `goToNextLog()` — FileTxnLog.java:601-608**
```java
if (storedFiles.size() > 0) {                     // false
    this.logFile = storedFiles.remove(...);
    ia = createInputArchive(this.logFile);        // <— never called
    return true;
}
return false;
```
Because this branch is not taken, `createInputArchive` (line 633) never runs, so `inputStream` stays `null`.

**4. The NPE site — `FileTxnLog.rollBack`, FileTxnLog.java:376-394**
```java
itr = new FileTxnIterator(this.logDir, zxid);
PositionInputStream input = itr.inputStream;   // null
long pos = input.getPosition();                // line 381  ← NPE
```
No null check on `itr.inputStream`; the code assumes the iterator always opened a file.

**5. Wrong catch clause in the observer main loop — `Observer.observeLeader`, Observer.java:70-95**
```java
try {
    ...
    syncWithLeader(newLeaderZxid);              // throws NullPointerException
    ...
} catch (IOException e) {                       // line 85 — does NOT match NPE
    LOG.warn("Exception when observing the leader", e);
    try { sock.close(); } catch (IOException e1) { ... }   // line 88  ← never runs
    pendingRevalidations.clear();
}
```
Because the caught type is `IOException` and the thrown type is `NullPointerException`, the `sock.close()` on line 88 is skipped. The TCP connection to the leader is not closed on this thread; the leader eventually closes its side, leaving the observer's descriptor half-closed (CLOSE_WAIT).

**6. Loop restarts without closing the socket — `QuorumPeer.run`, QuorumPeer.java:957-969**
```java
case OBSERVING:
    try {
        setObserver(makeObserver(logFactory));
        observer.observeLeader();               // line 961 — NPE escapes here
    } catch (Exception e) {                     // line 962 — swallows NPE
        LOG.warn("Unexpected exception", e);
    } finally {
        observer.shutdown();                    // line 965 — see below
        setObserver(null);
        updateServerState();                    // line 967 → sets state LOOKING
    }
```

**7. `Learner.shutdown` never touches `sock` — Learner.java:581-590**
```java
public void shutdown() {
    self.cnxnFactory.setZooKeeperServer(null);
    self.cnxnFactory.closeAll();      // closes client-facing NIO connections only
    if (zk != null) zk.shutdown();
    // <-- no sock.close() and no closeSocket() helper
}
```
`Observer.shutdown` (Observer.java:163-166) just delegates to `super.shutdown()`, so the learner→leader `sock` established by `connectToLeader` (Learner.java:228/242) is never closed. Combined with the missed catch in step 5, every failed observing attempt leaks one socket to the leader.

**8. `updateServerState` sends the peer straight back into election — QuorumPeer.java:1018-1023**
```java
if (!reconfigFlag) {
    setPeerState(ServerState.LOOKING);
    LOG.warn("PeerState set to LOOKING");
    return;
}
```
So the outer `while` re-enters LOOKING → OBSERVING → `observeLeader` → same ROLLBACK → same NPE → another leaked socket, many times per second, indefinitely — exactly the symptom.

### One-sentence summary
The observer boots with a stale snapshot whose zxid is ahead of the rebuilt leader; the leader replies with `ROLLBACK`; `FileTxnLog.rollBack` dereferences `itr.inputStream` at FileTxnLog.java:381 without checking that the (now-empty) txnlog directory produced a file, so it throws `NullPointerException`; `Observer.observeLeader` at Observer.java:85 catches only `IOException` and therefore skips `sock.close()`, while `Learner.shutdown` (Learner.java:581) also never closes `sock` — so QuorumPeer's outer loop resets the peer to LOOKING (QuorumPeer.java:962-967, 1020) and re-observes forever, leaking one leader socket per attempt.
