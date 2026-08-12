# Ground truth — Zookeeper-1900 (answer key, never shown to the diagnosis LLM)

Derived from `private/fix.diff` (trunk fix commit `6abd85938`, parent/pre-fix
`8cfb9a0ef`). The fix changes **two production lines**, in two files, plus a regression
test. Both changed sites are on the reproduced failure path. Line numbers below are those
of the anonymized tree in `source/` — identical to the pre-fix tree, since the
anonymization only renames identifiers (`truncate*`/`TRUNC` → `rollBack*`/`ROLLBACK`).

---

## Site 1 (root cause) — `FileTxnLog.rollBack(long zxid)` dereferences a null stream

`source/src/java/main/org/apache/zookeeper/server/persistence/FileTxnLog.java:376-381`

```java
376:    public boolean rollBack(long zxid) throws IOException {        // upstream: truncate
377:        FileTxnIterator itr = null;
378:        try {
379:            itr = new FileTxnIterator(this.logDir, zxid);
380:            PositionInputStream input = itr.inputStream;   //  <-- may be null
381:            long pos = input.getPosition();                //  <-- NullPointerException
```

**The wrong branch: there is none.** The code takes `itr.inputStream` and dereferences it
unconditionally — it assumes the freshly built `FileTxnIterator` always found a
transaction-log file. The upstream fix inserts exactly the missing guard between 380 and
381:

```java
if (input == null) {
    throw new IOException("No log files found to truncate! This could happen if you "
        + "still have snapshots from an old setup or log files were deleted "
        + "accidentally or dataLogDir was changed in zoo.cfg.");
}
```

**The exact condition under which `itr.inputStream` is null** (same file, inner class
`FileTxnIterator`):

* `init()` (lines 566-582) builds `storedFiles` from
  `Util.sortDataDir(FileTxnLog.getLogFiles(logDir.listFiles(), 0), "log", false)`. When the
  configured transaction-log directory contains **no `log.*` file at all**, that list is
  empty and the `for` loop adds nothing, so `storedFiles` stays empty.
* `goToNextLog()` (lines 601-608) therefore takes its `if (storedFiles.size() > 0)` branch
  as false and returns `false` **without** calling `createInputArchive()` — and
  `createInputArchive()` (lines 633-639, `if (inputStream == null) { inputStream = new
  PositionInputStream(...) }`) is the only place `inputStream` is ever assigned.
* So `inputStream` is still `null` when `rollBack()` reads it at line 380.

A run must name line 380/381 (the unguarded `itr.inputStream` / `input.getPosition()`) **and**
state that condition — the log directory holding no transaction-log file, hence
`storedFiles` empty / `goToNextLog()` false / `createInputArchive()` never called.

## Site 2 (required) — `Observer.observeLeader()` catches only `IOException`

`source/src/java/main/org/apache/zookeeper/server/quorum/Observer.java:85`

```java
79:                syncWithLeader(newLeaderZxid);      // throws the NPE from Site 1
...
85:            } catch (IOException e) {               // <-- fix: catch (Exception e)
86:                LOG.warn("Exception when observing the leader", e);
87:                try {
88:                    sock.close();                   // <-- never runs
...
94:                pendingRevalidations.clear();        // <-- never runs
```

**The wrong branch condition:** the handler is selected on `e instanceof IOException`, but a
`NullPointerException` is a `RuntimeException`, so the catch does not apply. Consequences:

1. `sock.close()` at line 88 is skipped, so the observer's TCP connection to the leader is
   never closed. The leader's `LearnerHandler` dies ("Unexpected exception causing shutdown
   while sock still open" / "GOODBYE"), the peer's socket goes to **CLOSE_WAIT**, and
   `Learner.shutdown()` (Learner.java:581-590) does not close `sock` either — one leaked
   socket per attempt.
2. The exception unwinds out of `observeLeader()` into `QuorumPeer.run()`'s
   `case OBSERVING: ... catch (Exception e) { LOG.warn("Unexpected exception", e); }
   finally { observer.shutdown(); setObserver(null); updateServerState(); }`
   (QuorumPeer.java:957-969) → peer state `LOOKING` → re-election → `OBSERVING` → the same
   failure, forever.

The upstream fix widens line 85 to `catch (Exception e)`. (The branch-3.4 patch makes the
same change in `Follower.java`; on this trunk `Follower.followLeader()` already catches
`Exception`, which is why only an **observer** exercises this site.)

---

## Supporting context (expected in a good answer, but NOT required for a PASS)

These lines are not changed by the fix; they explain why the roll-back is requested and why
the loop never converges:

* `LearnerHandler.syncFollower`, `else if (peerLastZxid > maxCommittedLog &&
  !isPeerNewEpochZxid)` → `queueOpPacket(Leader.ROLLBACK, maxCommittedLog)`
  (LearnerHandler.java:708-714). The observer's last zxid comes from its old snapshot and is
  ahead of the re-provisioned quorum, so the leader orders it to roll back.
* `Learner.syncWithLeader`, `else if (qp.getType() == Leader.ROLLBACK)` →
  `zk.getZKDatabase().rollBackLog(qp.getZxid())` (Learner.java:344-348) → `ZKDatabase.rollBackLog`
  (ZKDatabase.java:500-504, which calls `clear()` first) → `FileTxnSnapLog.rollBackLog`
  (FileTxnSnapLog.java:311-317) → Site 1.
* Because `ZKDatabase.clear()` sets `initialized = false` and the NPE aborts before
  `loadDataBase()` is reached, `QuorumPeer.getLastLoggedZxid()` reloads the same old
  snapshot on the next attempt — the observer reports the same too-high zxid every time, so
  every retry takes the same branch.

---

## Grading rule (decided before any run was read; §8 — no partial credit)

> Re-issued 2026-08-12 together with the rewritten `symptom.md`, after `context/METHODOLOGY.md`
> §5/M5 was tightened to "bare observable + log pointer, nothing else". The two required
> sites are unchanged; only the justification for B is restated, since the symptom no longer
> mentions the socket growth. Both runs' worth of grading (the discarded batch and the new
> one) used the same two-site bar.

A run **PASSes** iff it names **both** required sites with their conditions:

* **A.** `FileTxnLog.rollBack` line 380/381 — the unguarded `itr.inputStream` /
  `input.getPosition()` — identified as the root cause, **and** the exact condition that
  makes it null: the transaction-log directory contains no `log.*` file, so
  `FileTxnIterator.init()` leaves `storedFiles` empty, `goToNextLog()` returns false and
  `inputStream` is never created. (Naming the fix — a null check / IOException — is not
  required, but the missing guard must be identified.)
* **B.** `Observer.observeLeader` line 85 — `catch (IOException e)` does not catch the
  `NullPointerException` (a `RuntimeException`), so the handler is skipped (`sock.close()`
  at 88 never runs) and the exception escapes to `QuorumPeer.run`. Naming the leaked
  socket / CLOSE_WAIT consequence is **not** required (it is no longer part of the stated
  symptom); identifying the catch clause as too narrow, and that the exception therefore
  leaves `observeLeader` unhandled, is.

  *Why B is required even though the symptom no longer mentions sockets:* §10 of the
  methodology requires every site the fix touched, and this one is directly evidenced by the
  pasted symptom itself — the trace's top frame is `QuorumPeer.run(QuorumPeer.java:961)`
  under a `QuorumPeer@963 "Unexpected exception"` WARN, which can only happen because the
  handler at `Observer.java:85` did not apply to a `RuntimeException`.

Anything less is a **FAIL**: right file/wrong line, right line without the branch condition,
naming only A, naming only B, or hedged answers with no concrete lines. Mentioning `Follower.followLeader` instead
of `Observer.observeLeader` does not satisfy B (the failing member is an observer and
`Follower` already catches `Exception` in this tree). Extra correct findings (the
`LearnerHandler`/`Learner` branches above) are credit-neutral.
