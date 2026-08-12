I've traced the entire failure path. Here's the diagnosis.

## Root cause

The observer (myid=4) has an inconsistent on-disk state after the maintenance:
- Its **snapDir** was preserved. It contains the old `snapshot.100001013` (last processed zxid ≈ `0x100001013`, from before the outage).
- Its **txnlog dir** was moved to a fresh replacement volume (`/tmp/zk-repro-tPiT/hosts/zk4/txnlog-vol2`), which is empty.
- The three participants were re-provisioned on empty storage, so their zxid restarts around `0x1……` in new epoch 1 (leader is at `0x10000023d`).

Because the observer replays the preserved snapshot on startup it reports a zxid **ahead of the leader**, so the leader answers OBSERVERINFO with `ROLLBACK`. That drives execution into a rollback code path that assumes at least one txnlog file exists in `dataDir` — and there are none, because that dir was replaced with a blank volume.

## The exact branches that fail

1. **Observer loads the stale snapshot** — `logs/server_4.log` line 244148 (`Reading snapshot .../snapshot.100001013`) after `FileTxnSnapLog` opened `txnlog-vol2` at 244141. Observer state advances past the leader's zxid.

2. **Leader replies ROLLBACK**, taking the `Leader.ROLLBACK` branch in
   `source/src/java/main/org/apache/zookeeper/server/quorum/Learner.java:344-354` — specifically the call `zk.getZKDatabase().rollBackLog(qp.getZxid())` at **Learner.java:348**.

3. `ZKDatabase.rollBackLog` (line 504) delegates to `FileTxnSnapLog.rollBackLog` (line 317), which calls
   `FileTxnLog.rollBack(zxid)` in
   `source/src/java/main/org/apache/zookeeper/server/persistence/FileTxnLog.java:376-395`.

4. **The empty-directory branch inside `FileTxnIterator.init()`** (FileTxnLog.java:566-582):
   - `logDir.listFiles()` returns no `log.*` files, so the `for` loop at line 569 never adds anything to `storedFiles`.
   - `goToNextLog()` at line 579 returns `false` because `storedFiles.size() > 0` at line 602 is false.
   - `next()` at 580 also returns `false`.
   - Consequently `createInputArchive()` (line 633) is never called and `inputStream` stays `null` (initialised at line 522).

5. Back in `rollBack()`:
   - **FileTxnLog.java:380** — `PositionInputStream input = itr.inputStream;` → `input == null`.
   - **FileTxnLog.java:381** — `long pos = input.getPosition();` throws `NullPointerException` (matches the stack trace at symptom.log:244231-244238).

6. **The NPE escapes the observer's own catch block.** In `Observer.observeLeader`
   `source/src/java/main/org/apache/zookeeper/server/quorum/Observer.java:67-99` the inner try (line 73) only catches `IOException` at line 85. A `NullPointerException` from `syncWithLeader` (line 79) bypasses both `sock.close()` (line 88) and `pendingRevalidations.clear()` (line 94), and propagates to `QuorumPeer.run` case `OBSERVING` (**QuorumPeer.java:957-968**) where it is logged as "Unexpected exception" (line 244231 in the log).

7. The `finally` at QuorumPeer.java:964-968 calls `observer.shutdown()`, which reaches `Learner.shutdown()` in
   `source/src/java/main/org/apache/zookeeper/server/quorum/Learner.java:581-590`. **That method never closes `sock`** — it only clears connections in `cnxnFactory` and shuts down `zk`. The leader-side socket that was opened by `connectToLeader` (Learner.java:228/242) is orphaned. The leader closes its end when the observer disappears, leaving the observer's fd in `CLOSE_WAIT`.

8. `PeerState` is reset to `LOOKING` (QuorumPeer.java:1021 log at 244245), fast leader election runs, the observer re-enters `OBSERVING`, and the same rollback path fails again — one new leaked socket per iteration, growing without bound. Because `syncWithLeader` never completes, `ObserverZooKeeperServer` never registers, hence "not currently serving requests" for clients on its client port.

## Summary of the causal branches

| # | File:line | Condition taken |
|---|-----------|-----------------|
| 1 | `Learner.java:344` | `qp.getType() == Leader.ROLLBACK` — because observer's snapshot zxid > leader's zxid |
| 2 | `FileTxnLog.java:602` (`goToNextLog`) | `storedFiles.size() > 0` is **false** — new volume has no `log.*` |
| 3 | `FileTxnLog.java:634` (`createInputArchive`) | never reached, so `inputStream` remains `null` |
| 4 | `FileTxnLog.java:381` | `input.getPosition()` on `null` → NPE |
| 5 | `Observer.java:85` | catch is `IOException` only, so NPE escapes without `sock.close()` |
| 6 | `Learner.java:581` (`shutdown`) | no branch closes `sock` — socket leaks in CLOSE_WAIT |
| 7 | `QuorumPeer.java:962` | catch logs and falls through to LOOKING → retry loop |

The fix condition is straightforward: the observer's `dataDir` (txnlog directory) must be consistent with its `snapDir`. Because the maintenance replaced the txnlog volume without also wiping the snapshot dir, ZooKeeper's rollback path dereferences an unopened `PositionInputStream` and the observer never gets past `syncWithLeader`.
