## Root cause

The observer's **snap dir was preserved but its txnlog dir was replaced with an empty volume**. It loads the old snapshot (last zxid ≈ `0x100001013`, per `Reading snapshot /tmp/.../snapshot.100001013` at server_4.log:244148) but has *no* `log.*` files. The re-provisioned participants start a fresh epoch — the leader's max zxid is `0x10000023d`, which is **smaller** than the observer's in-memory zxid. So the leader tells the observer to TRUNC, and the observer tries to roll back a transaction log that doesn't exist on disk.

The exception in every attempt (server_4.log:244231-244238) is:

```
java.lang.NullPointerException
    at FileTxnLog.rollBack(FileTxnLog.java:381)
    at FileTxnSnapLog.rollBackLog(FileTxnSnapLog.java:317)
    at ZKDatabase.rollBackLog(ZKDatabase.java:504)
    at Learner.syncWithLeader(Learner.java:348)
    at Observer.observeLeader(Observer.java:79)
    at QuorumPeer.run(QuorumPeer.java:961)
```

### The exact branches that fire

1. **`Learner.syncWithLeader` — Learner.java:344** takes the `else if (qp.getType() == Leader.ROLLBACK)` branch (leader's zxid < observer's snapshot zxid), and at **Learner.java:348** calls `zk.getZKDatabase().rollBackLog(qp.getZxid())`.

2. **`FileTxnLog.rollBack` — FileTxnLog.java:376–394** constructs `new FileTxnIterator(this.logDir, zxid)` at line 379 against the empty `txnlog-vol2` directory.

3. **`FileTxnIterator.init` — FileTxnLog.java:566–582** builds `storedFiles` from `logDir.listFiles()`. The listing is empty, so the `for (File f: files)` loop never executes and `storedFiles` stays empty. It then calls `goToNextLog()`.

4. **`FileTxnIterator.goToNextLog` — FileTxnLog.java:601–608** takes the false branch of `if (storedFiles.size() > 0)` and returns `false` without calling `createInputArchive`. Because `createInputArchive` (line 633) is the *only* place `inputStream` is assigned (line 635), `inputStream` remains its default `null` (declared line 522).

5. Back in **`rollBack` — FileTxnLog.java:380–381**:
   ```java
   PositionInputStream input = itr.inputStream;   // null
   long pos = input.getPosition();                // NPE
   ```
   That is the line reported in the stack trace.

6. **`Observer.observeLeader` — Observer.java:67–95** wraps the `syncWithLeader` call at line 79 with `try { … } catch (IOException e) { … sock.close(); … }` (line 85). NPE is a `RuntimeException`, not an `IOException`, so **the catch does not fire and `sock.close()` at line 88 is skipped**. The NPE propagates to `QuorumPeer.run`.

7. **`QuorumPeer.run` — QuorumPeer.java:957–968** catches the exception at line 962 (`case OBSERVING`), logs `Unexpected exception`, and runs the `finally` at 964–967: `observer.shutdown(); setObserver(null); updateServerState();`.

8. **`Observer.shutdown` — Observer.java:163–166** just calls `super.shutdown()` → **`Learner.shutdown` — Learner.java:581–590**, which only closes the client-facing `cnxnFactory` and the local `zk`. It **never touches `Learner.sock`** (the TCP connection to the leader created in `connectToLeader` at Learner.java:228/242). The leader's side of that socket was closed when the observer disappeared, so the FD sits in **CLOSE_WAIT** on the observer forever.

9. **`updateServerState` — QuorumPeer.java:1018–1023** takes the `!reconfigFlag` branch and sets state to `LOOKING`. The outer `while (running)` loop re-elects (leader 3 wins again), flips back to `OBSERVING`, allocates a **new** `sock` in `connectToLeader`, and repeats step 1 — many times per second, one leaked CLOSE_WAIT socket per iteration, forever.

### One-line summary

Stale snapshot + empty new txnlog dir ⇒ leader sends TRUNC ⇒ `FileTxnLog.rollBack` builds a `FileTxnIterator` over an empty directory, so its `inputStream` is never initialized, and `input.getPosition()` at **FileTxnLog.java:381** throws NPE; `Observer.observeLeader`'s catch at **Observer.java:85** only handles `IOException`, so the leader socket is never closed and CLOSE_WAIT descriptors accumulate one per retry while the peer flips OBSERVING↔LOOKING indefinitely.
