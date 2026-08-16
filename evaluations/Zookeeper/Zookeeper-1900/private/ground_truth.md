# Ground truth — Zookeeper-1900 (answer key, never shown to the diagnosis LLM)

Derived from `private/fix.diff` (trunk fix commit `6abd85938`, parent/pre-fix `8cfb9a0ef`).
The fix changes **two production lines**, in two files, plus a regression test. Both changed
sites are on the reproduced failure path.

Per METHODOLOGY §5/M5 step 2 every location is given **twice**: the real upstream name and the
**anonymized** name as it appears in `source/` and in `logs/symptom.log` (map:
`private/anonymization_map.json`). Line numbers are identical in both trees — the anonymization
is a pure in-line substitution.

| real (upstream) | anonymized (`source/`) |
|---|---|
| `FileTxnLog` | `TxnJournal` |
| `FileTxnLog.FileTxnIterator` | `TxnJournal.TxnJournalIterator` |
| `FileTxnSnapLog` | `JournalSnapStore` |
| `ZKDatabase` | `ZKStateStore` |
| `Learner` | `PeerSynchronizer` |
| `LearnerHandler` | `PeerSyncHandler` |
| `Observer` | `ObserverPeer` |
| `QuorumPeer` | `EnsembleMember` |
| `truncate` / `truncateLog` / `TRUNC` | `rollBack` / `rollBackLog` / `ROLLBACK` |

---

## Site 1 (root cause) — `FileTxnLog.truncate` dereferences a null stream

real: `FileTxnLog.java:376-381`, method `truncate(long zxid)`
anonymized: `source/src/java/main/org/apache/zookeeper/server/persistence/TxnJournal.java:376-381`,
method `rollBack(long zxid)`

```java
376:    public boolean rollBack(long zxid) throws IOException {     // upstream: truncate
377:        TxnJournalIterator itr = null;                          // upstream: FileTxnIterator
378:        try {
379:            itr = new TxnJournalIterator(this.logDir, zxid);
380:            PositionInputStream input = itr.inputStream;   //  <-- may be null
381:            long pos = input.getPosition();                //  <-- NullPointerException
```

**The wrong branch: there is none.** `itr.inputStream` is dereferenced unconditionally — the
code assumes the freshly built iterator always found a transaction-log file. The upstream fix
inserts exactly the missing guard between 380 and 381:

```java
if (input == null) {
    throw new IOException("No log files found to truncate! This could happen if you "
        + "still have snapshots from an old setup or log files were deleted "
        + "accidentally or dataLogDir was changed in zoo.cfg.");
}
```

**The exact condition under which `itr.inputStream` is null** (same file, inner class
`FileTxnIterator` / `TxnJournalIterator`):

* `init()` (566-582) builds `storedFiles` from
  `Util.sortDataDir(getLogFiles(logDir.listFiles(), 0), "log", false)`. When the configured
  transaction-log directory contains **no `log.*` file at all**, that list is empty, the `for`
  loop adds nothing, and `storedFiles` stays empty.
* `goToNextLog()` (601-608) therefore takes `if (storedFiles.size() > 0)` as false and returns
  `false` **without** calling `createInputArchive()` — and `createInputArchive()` (633-639,
  `if (inputStream == null) { inputStream = new PositionInputStream(...) }`) is the only place
  `inputStream` is ever assigned (declared `null` at 522).
* So `inputStream` is still `null` when the roll-back reads it at line 380.

A run must name line 380/381 (the unguarded `itr.inputStream` / `input.getPosition()`) **and**
state that condition — the log directory holding no transaction-log file, hence `storedFiles`
empty / `goToNextLog()` false / `createInputArchive()` never called.

## Site 2 (required) — `Observer.observeLeader()` catches only `IOException`

real: `Observer.java:85` · anonymized:
`source/src/java/main/org/apache/zookeeper/server/quorum/ObserverPeer.java:85`

```java
79:                syncWithLeader(newLeaderZxid);      // throws the NPE from Site 1
...
85:            } catch (IOException e) {               // <-- fix: catch (Exception e)
86:                LOG.warn("Error while following the current leader", e);
87:                try {
88:                    sock.close();                   // <-- never runs
...
94:                pendingRevalidations.clear();       // <-- never runs
```

**The wrong branch condition:** the handler is selected on `e instanceof IOException`, but a
`NullPointerException` is a `RuntimeException`, so the catch does not apply. Consequences:

1. `sock.close()` at 88 is skipped, so the connection to the leader is never closed
   (`Learner.shutdown()` / `PeerSynchronizer.shutdown()` at 581-590 does not close `sock`
   either) — one leaked socket per attempt, ending in CLOSE_WAIT.
2. The exception unwinds into `QuorumPeer.run()` / `EnsembleMember.run()`'s
   `case OBSERVING: ... catch (Exception e) { LOG.warn("Unhandled error in the peer state
   machine", e); } finally { observer.shutdown(); setObserver(null); updateServerState(); }`
   (957-969) → `LOOKING` → re-election → `OBSERVING` → the same failure, forever. That WARN at
   963 is the line quoted in `symptom.md`.

The upstream fix widens line 85 to `catch (Exception e)`. (The branch-3.4 patch makes the same
change in `Follower.java`; on this trunk `Follower.followLeader()` already catches `Exception`,
which is why only an **observer** exercises this site.)

---

## Supporting context (expected in a good answer, but NOT required for a PASS)

Not changed by the fix; explains why the roll-back is requested and why the loop never converges:

* `LearnerHandler.syncFollower` / `PeerSyncHandler.syncFollower`, branch
  `peerLastZxid > maxCommittedLog && !isPeerNewEpochZxid` → `queueOpPacket(Leader.ROLLBACK,
  maxCommittedLog)` (708-714). The observer's last zxid comes from its old snapshot and is ahead
  of the re-provisioned quorum, so the leader orders it to roll back.
* `Learner.syncWithLeader` / `PeerSynchronizer.syncWithLeader`, `else if (qp.getType() ==
  Leader.ROLLBACK)` → `zk.getZKStateStore().rollBackLog(qp.getZxid())` (344-348) →
  `ZKStateStore.rollBackLog` (500-504, which calls `clear()` first) → `JournalSnapStore.rollBackLog`
  (311-317) → Site 1.
* Because `clear()` sets `initialized = false` and the NPE aborts before `loadDataBase()` is
  reached, `getLastLoggedZxid()` reloads the same old snapshot on the next attempt — the observer
  reports the same too-high zxid every time, so every retry takes the same branch.

---

## Grading rule (decided before any run was read; §8 — no partial credit)

> Re-issued 2026-08-16 for the third batch: `source/` and both logs were regenerated under the
> rewritten M4 (failure-path type + log-literal renames) and the LLM now receives the merged
> 1.6 GB production log. The two required sites and the bar are unchanged from the previous
> batch; only the names the LLM will use have changed, and the table above translates them.

A run **PASSes** iff it names **both** required sites with their conditions. The LLM will use the
anonymized names; translate through the table above and match by **code identity**, not by line
number.

* **A.** `TxnJournal.rollBack` (= `FileTxnLog.truncate`) line 380/381 — the unguarded
  `itr.inputStream` / `input.getPosition()` — identified as the root cause, **and** the exact
  condition that makes it null: the transaction-log directory contains no `log.*` file, so
  `init()` leaves `storedFiles` empty, `goToNextLog()` returns false and `inputStream` is never
  created. (Naming the fix — a null check / IOException — is not required, but the missing guard
  must be identified.)
* **B.** `ObserverPeer.observeLeader` (= `Observer.observeLeader`) line 85 — `catch (IOException e)`
  does not catch the `NullPointerException` (a `RuntimeException`), so the handler is skipped
  (`sock.close()` at 88 never runs) and the exception escapes to `EnsembleMember.run`. Naming the
  leaked socket / CLOSE_WAIT consequence is **not** required (it is not part of the stated
  symptom); identifying the catch clause as too narrow, and that the exception therefore leaves
  `observeLeader` unhandled, is.

  *Why B is required even though the symptom does not mention sockets:* §10 of the methodology
  requires every site the fix touched, and this one is directly evidenced by the pasted symptom
  itself — the trace's top frame is `EnsembleMember.run(EnsembleMember.java:961)` under an
  `EnsembleMember@963 "Unhandled error in the peer state machine"` WARN, which can only happen
  because the handler at `ObserverPeer.java:85` did not apply to a `RuntimeException`.

Anything less is a **FAIL**: right file/wrong line, right line without the branch condition,
naming only A, naming only B, or hedged answers with no concrete lines. Mentioning
`Follower.followLeader` instead of `ObserverPeer.observeLeader` does not satisfy B (the failing
member is an observer and `Follower` already catches `Exception` in this tree). Extra correct
findings (the `PeerSyncHandler` / `PeerSynchronizer` branches above, or the second route to a
null stream via the fast-forward EOF path) are credit-neutral.
