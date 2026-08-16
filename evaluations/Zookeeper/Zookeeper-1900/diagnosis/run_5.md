## Root cause

`myid=4` is an **Observer** (`ObserverPeer@72 - Observing /127.0.0.1:24623`). After it restarted at `19:06:27,419` (see the MBean *Unregister* line right before the first NPE), it reconnected to the leader, and the very first sync packet it received was a `Leader.ROLLBACK`. That drives it into `TxnJournal.rollBack`, which unconditionally dereferences an `inputStream` that the iterator never set — hence the `NullPointerException` at `TxnJournal.java:381`.

## The exact failure path

1. **`PeerSynchronizer.syncWithLeader`** (`PeerSynchronizer.java:320`) reads the first sync packet. In this run it takes the `Leader.ROLLBACK` branch:

   ```java
   } else if (qp.getType() == Leader.ROLLBACK) {                       // line 344
       LOG.warn("Rewinding the transaction journal to match the leader …");
       boolean rolledBack = zk.getZKStateStore().rollBackLog(qp.getZxid()); // line 348 ← stack frame
   ```

2. **`ZKStateStore.rollBackLog(long zxid)`** (`ZKStateStore.java:500`) throws away all *in-memory* state before touching disk:

   ```java
   public boolean rollBackLog(long zxid) throws IOException {
       clear();                                                        // line 501 — new DataTree, etc.
       boolean rolledBack = snapLog.rollBackLog(zxid);                 // line 504 ← stack frame
   ```

3. **`JournalSnapStore.rollBackLog(long zxid)`** (`JournalSnapStore.java:311`) closes the current txn/snap handles and drives the rollback through a *brand-new* `TxnJournal`:

   ```java
   close();
   TxnJournal rbLog = new TxnJournal(dataDir);
   boolean rolledBack = rbLog.rollBack(zxid);                          // line 317 ← stack frame
   ```

4. **`TxnJournal.rollBack(long zxid)`** (`TxnJournal.java:376`) — the crash site:

   ```java
   public boolean rollBack(long zxid) throws IOException {
       TxnJournalIterator itr = null;
       try {
           itr = new TxnJournalIterator(this.logDir, zxid);            // line 379
           PositionInputStream input = itr.inputStream;                // line 380
           long pos = input.getPosition();                             // line 381 ← NPE
           …
   ```
   `input` is `itr.inputStream`, and it can legitimately be `null` — the code never checks.

## Why `itr.inputStream` is null

`TxnJournalIterator` declares the field as
```java
PositionInputStream inputStream = null;                                 // line 522
```
The two-arg ctor at `TxnJournal.java:557` delegates to the three-arg ctor with `fastForward=true`, which calls `init()` (`TxnJournal.java:566`):

```java
void init() throws IOException {
    storedFiles = new ArrayList<File>();
    List<File> files = Util.sortDataDir(TxnJournal.getLogFiles(logDir.listFiles(), 0), "log", false);
    for (File f : files) {
        if (Util.getZxidFromName(f.getName(),"log") >= zxid)  storedFiles.add(f);
        else if (Util.getZxidFromName(f.getName(),"log") < zxid) { storedFiles.add(f); break; }
    }
    goToNextLog();                                                     // line 579
    if (!next()) return;                                               // line 580
}
```

`inputStream` is only set inside `createInputArchive` (line 634-640), which is only invoked from `goToNextLog()` (line 601) when `storedFiles` is non-empty. There are two branches where `init()` — and therefore the constructor — returns with `inputStream` still `null`:

* **Branch A — no log files match at all.** `storedFiles` is empty ⇒ `goToNextLog()` line 602 (`if (storedFiles.size() > 0)`) is false, it returns without opening a file; then in `next()` (line 657) the guard `if (ia == null) return false;` (line 658-660) fires immediately. `inputStream` was never assigned.

* **Branch B — every log opened runs off the end during fast-forward.** In `next()`'s EOF handler (line 678-690) the code deliberately clears the stream:
  ```java
  } catch (EOFException e) {
      inputStream.close();
      inputStream = null;                                              // line 681
      ia = null;
      hdr = null;
      if (!goToNextLog()) return false;                                // line 686
      return next();
  }
  ```
  If `goToNextLog()` at line 686 returns `false` (nothing left in `storedFiles`), `next()` returns with `inputStream == null`. This also fires from the outer fast-forward loop in the constructor:
  ```java
  if (fastForward && hdr != null) {                                    // line 543
      while (hdr.getZxid() < zxid) {                                   // line 544
          if (!next()) break;                                          // line 545
      }
  }
  ```
  When the target `zxid` is greater than every txn in every remaining log file, this loop drains the iterator to EOF, hits Branch B, and leaves `inputStream = null`.

Both branches feed the same defect: **`rollBack` at line 380–381 assumes the iterator opened at least one log file, but `init()`/`next()` can return with no file open.** The immediate `input.getPosition()` therefore NPEs.

## Why this Observer fell into it

Log evidence for `myid=4`:

- Fresh restart at `19:06:27,419` (`Environment@109` + `MBean … Unregister`).
- On reconnect it takes the `Leader.ROLLBACK` branch of `PeerSynchronizer.syncWithLeader` (that's the only path in `syncWithLeader` that reaches `ZKStateStore.rollBackLog` in the stack trace).
- The leader's rollback target `zxid` does not correspond to any transaction present in this Observer's `logDir` after the restart (`storedFiles` empty, or fast-forward past every txn) — so the iterator satisfies Branch A/B above.
- The `role shutdown requested` at `19:06:27,518` and the endlessly repeating warnings (`EnsembleMember@963`) show the peer loop restarting the observer state machine, immediately re-entering `syncWithLeader`, re-receiving the ROLLBACK, and re-hitting the same NPE — which is exactly why this member "is not serving client requests".

## Fix location

The defect is in `TxnJournal.rollBack` (`TxnJournal.java:376–395`): it must treat "iterator opened no log file" (i.e. `itr.inputStream == null`) as "nothing to roll back" (return `true`, or roll back only the files listed in `storedFiles`) instead of dereferencing `input`. Equivalently, `TxnJournalIterator.init` could guarantee `inputStream != null` on successful construction. The two `null`-producing branches to guard are the empty-`storedFiles` branch at `TxnJournal.java:602` and the EOF branch at `TxnJournal.java:681/686`.
