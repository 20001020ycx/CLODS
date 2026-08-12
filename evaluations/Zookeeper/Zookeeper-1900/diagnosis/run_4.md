## Root Cause

The NPE originates at `FileTxnLog.rollBack()` line 381 because `itr.inputStream` (the field aliased into local `input` on line 380) is **still `null`** when `getPosition()` is dereferenced. The `FileTxnIterator` constructor never opened any file: the observer's transaction‑log directory contained no `log.*` files at all when the leader told it to roll back.

### The failing path, step by step

1. **`Learner.syncWithLeader` — `Learner.java:344‑348`** — the leader's first sync packet is `Leader.ROLLBACK`, so the branch
   ```java
   else if (qp.getType() == Leader.ROLLBACK) {
       ...
       boolean rolledBack = zk.getZKDatabase().rollBackLog(qp.getZxid());   // line 348
   }
   ```
   is taken (this is why the trace passes through `Observer.observeLeader:79 → syncWithLeader:348`, not through the `DIFF`/`SNAP` branches).

2. **`FileTxnLog.rollBack` — `FileTxnLog.java:376‑395`** — creates a new iterator and immediately reads its stream:
   ```java
   itr = new FileTxnIterator(this.logDir, zxid);       // line 379
   PositionInputStream input = itr.inputStream;        // line 380  ← copies the field
   long pos = input.getPosition();                     // line 381  ← NPE here
   ```
   There is no null check on `itr.inputStream` before it is dereferenced.

3. **`FileTxnIterator` field default — `FileTxnLog.java:522`** — the field starts as `null`:
   ```java
   PositionInputStream inputStream = null;
   ```

4. **`FileTxnIterator.init()` — `FileTxnLog.java:566‑582`** builds `storedFiles` from `getLogFiles(logDir.listFiles(), 0)`. If no log file has a name matching `log.<hex>` (i.e. the directory has been wiped, was never populated, or contains only snapshots), the `for (File f: files)` loop adds nothing and `storedFiles` remains empty. Then:
   ```java
   goToNextLog();     // line 579
   if (!next()) return;   // line 580‑581
   ```

5. **`FileTxnIterator.goToNextLog()` — `FileTxnLog.java:601‑608`** — takes the *empty‑list* branch:
   ```java
   if (storedFiles.size() > 0) {           // FALSE
       this.logFile = storedFiles.remove(storedFiles.size()-1);
       ia = createInputArchive(this.logFile);   // ← this is where inputStream would be set
       return true;
   }
   return false;                            // ← taken; inputStream never assigned
   ```
   `createInputArchive` (line 633‑642) is the only place `inputStream` is ever constructed, so skipping it leaves the field `null`.

6. **`FileTxnIterator.next()` — `FileTxnLog.java:657‑660`** — because `goToNextLog` never set `ia`, the guard
   ```java
   if (ia == null) return false;
   ```
   returns immediately, leaving `hdr == null`.

7. Back in the constructor (`FileTxnLog.java:543‑548`), the fast‑forward is skipped because `hdr == null`:
   ```java
   if (fastForward && hdr != null) { ... }
   ```
   So control returns to `rollBack`, and step 2 dereferences the still‑null field.

8. **`QuorumPeer.run` — `QuorumPeer.java:957‑968`** catches the NPE at line 963 (`LOG.warn("Unexpected exception", e)`), tears the observer down in the `finally`, and re‑enters `case OBSERVING`. The leader replays the same ROLLBACK, and the same NPE fires again — hence the message repeating thousands of times.

### The exact logical condition that dictates the failure

`FileTxnLog.rollBack` (line 380–381) unconditionally reads `itr.inputStream.getPosition()`, but `FileTxnIterator` guarantees `inputStream` is non‑null **only when `goToNextLog()` finds at least one file**, i.e. when

```java
Util.sortDataDir(FileTxnLog.getLogFiles(logDir.listFiles(), 0), "log", false)   // FileTxnLog.java:568
```

returns a non‑empty list. When the observer's `dataLogDir` holds no `log.<zxid>` file at the moment the leader sends `ROLLBACK`, that list is empty → `storedFiles` empty (line 567‑578) → `goToNextLog()` falls through the `if (storedFiles.size() > 0)` guard on line 602 and returns `false` without constructing `inputStream` on line 635 → `itr.inputStream` stays at its `null` initializer (line 522) → `input.getPosition()` on line 381 throws `NullPointerException`.

In short: the bug is a missing "no log files to roll back" guard in `FileTxnLog.rollBack` / `FileTxnIterator.goToNextLog`; the trigger is the observer being asked to roll back with an empty txn‑log directory.
