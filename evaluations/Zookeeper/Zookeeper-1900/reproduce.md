# Reproducing Zookeeper-1900 (pre-fix trunk `8cfb9a0ef`, ZooKeeper 3.5.0-SNAPSHOT)

## Scenario in one paragraph

A four-member ZooKeeper ensemble (three participants + one **observer**) runs normally and
serves a few thousand transactions; every member keeps its snapshots in `dataDir` and its
transaction logs in a separate `dataLogDir`, as production deployments commonly do. The
three participant machines are then re-provisioned on empty storage. The observer machine
is left alone **except** that its transaction-log volume is replaced: `dataLogDir` in its
`zoo.cfg` now points at a new, empty directory, while `dataDir` (its snapshots, `myid`,
`currentEpoch`/`acceptedEpoch`) is untouched. When the cluster is brought back up, the
observer never rejoins: every sync attempt dies, it cycles `LOOKING → OBSERVING` forever,
it cannot serve any client, and it leaks one connection to the leader per attempt.

## How to run it

```bash
cd /mnt/SSD-4T/ycx/CLODS
docker run --rm -v "$PWD:/work" clods-eval:Zookeeper-Zookeeper-1900 \
    -c 'bash /work/evaluations/Zookeeper/Zookeeper-1900/reproduce.sh'
```

`reproduce.sh` builds the pre-fix tree if needed (`ant jar`), runs the whole three-phase
scenario against real server processes, writes the collected log to
`private/symptom.orig.log` and prints its assertions to stdout. Ports are 24611-24614
(client), 24621-24624 (quorum), 24631-24634 (election). Knobs: `PREV_OPS`, `PREV_CLIENTS`,
`NEW_OPS`, `WATCH_SECS`, `REPO`, `OUT_LOG`.

For the anonymized re-run (M4) the same script is invoked by `private/anonymize.sh` with
`REPO` pointing at the renamed tree and `OUT_LOG=logs/symptom.log`.

## What the script actually does

**Phase A — the deployment as it ran before.** Four real `QuorumPeerMain` processes
(myid 1-3 participants, myid 4 `peerType=observer`), root logger *and* console appender at
`DEBUG`, `snapCount=300` so snapshots are written regularly. Roles are discovered with the
servers' own `srvr` four-letter word (leader 24613, followers 24611/24612, node 4
`Mode: observer`). Traffic is real and goes through the public API only: six concurrent
`Workload` clients (280 iterations each of create/getData/setData/exists/getChildren/
delete, spread over all three participants), a real `zkCli` shell session on the leader
(40 × create/get/set/stat, then 20 deletes), and a client doing ephemeral create/read/
delete work **through the observer**. The ensemble executes ~4 000 transactions; the
observer ends with 18 snapshots and 18 transaction logs, newest `snapshot.100000fc6`
(zxid 0x100000fc6). All four members are then stopped.

**Phase B — the operator action** (no ZooKeeper code involved, no files edited): the three
participants get brand-new empty `dataDir`/`dataLogDir`; the observer keeps its `dataDir`
and its `dataLogDir` is repointed at a new empty directory. This is exactly the situation
the upstream fix's own error message names ("*you still have snapshots from an old setup or
log files were deleted accidentally or dataLogDir was changed in zoo.cfg*").

**Phase C — the incident.** The three re-provisioned participants start, form a quorum
(epoch 1, leader 24613) and serve real traffic: two 120-iteration workloads plus a
long-running client that keeps doing ephemeral work for the whole 40 s window (185
operations, 0 failures — the quorum is healthy throughout). The observer is then started.
While it retries, the script samples its `/proc/<pid>/fd` and the container's CLOSE_WAIT
socket count every 5 s, and after 20 s an ordinary client is pointed at the observer's
client port.

## How the failure is triggered

The observer's last logged zxid comes from its old snapshot (`0x100000fc6` = 4038) because
its new `dataLogDir` is empty; the re-provisioned quorum is only at `0x1000003b0` = 944.
The observer's `acceptedEpoch` (1) equals the new cluster's epoch (1), so it is admitted,
and `LearnerHandler.syncFollower` takes the `peerLastZxid > maxCommittedLog` branch:

```
[myid:3] LearnerHandler@659 - Synchronizing with Follower sid: 4 maxCommittedLog=0x100000269
         minCommittedLog=0x100000075 lastProcessedZxid=0x100000269 peerLastZxid=0x100000fc6
[myid:3] LearnerHandler@710 - Sending TRUNC to follower zxidToSend=0x100000269 for peer sid:4
```

The learner then tries to cut its transaction log back to that zxid — and its log directory
holds no log file at all. Because the leader's zxid stays far below the observer's for the
whole window, **every** retry takes the same branch, so the loop never ends.

## How the failure is detected (silently)

No log or print statement is added to ZooKeeper or to the test harness. `Workload.java`
writes nothing to stdout/stderr; its observations go to `private/result_*.txt`, which the
script reads. Detection is by assertion on the servers' own logs, those result files and
`/proc`; assertion output goes to `reproduce.sh`'s stdout and is **never** written into the
symptom log. Observed in the recorded run:

| observable | value |
|---|---|
| `NullPointerException`s in the observer's log (40 s) | **6 239** |
| stack frames in the log-truncation path | 6 239 |
| `Truncating log to get in sync with the leader` | 6 239 |
| leader-side `Synchronizing with Follower sid: 4` | 6 239 |
| observer answering `srvr` | `This ZooKeeper instance is not currently serving requests` |
| ordinary client pointed at the observer | `connect=TIMEOUT ... waited_ms=20001 state=CONNECTING` |
| observer's open sockets, t=5 s → t=40 s | 25 → 122 |
| sockets in CLOSE_WAIT, t=5 s → t=40 s | 0 → 42 |
| client on the quorum during the same window | `collateral_ok=185 collateral_failed=0` |

The observer's own log shows one full iteration as:

```
WARN  Learner@346 - Truncating log to get in sync with the leader 0x10000023d
WARN  QuorumPeer@963 - Unexpected exception
java.lang.NullPointerException
    at org.apache.zookeeper.server.persistence.FileTxnLog.truncate(FileTxnLog.java:381)
    at org.apache.zookeeper.server.persistence.FileTxnSnapLog.truncateLog(FileTxnSnapLog.java:317)
    at org.apache.zookeeper.server.ZKDatabase.truncateLog(ZKDatabase.java:504)
    at org.apache.zookeeper.server.quorum.Learner.syncWithLeader(Learner.java:348)
    at org.apache.zookeeper.server.quorum.Observer.observeLeader(Observer.java:79)
    at org.apache.zookeeper.server.quorum.QuorumPeer.run(QuorumPeer.java:961)
INFO  Observer@164 - shutdown called
WARN  QuorumPeer@1021 - PeerState set to LOOKING
INFO  QuorumPeer@896 - LOOKING
...
INFO  QuorumPeer@959 - OBSERVING          <- and straight back into the same failure
```

(Line numbers are those of the pre-fix tree; the anonymized M4 re-run regenerates the log
from the renamed build, so its frames carry the renamed method names.)

## The captured log

`private/symptom.orig.log` — 524 674 lines / 75 MB, the concatenation of all four servers'
own DEBUG logs from both the previous deployment and the current one, plus every client
session log (241 073 DEBUG, 119 743 INFO, 31 333 WARN/ERROR lines). The only text the
script adds is one `===== file: <name> =====` header per collected file. There are **no**
injected, answer-revealing lines: nothing reports why the truncation fails, what the log
directory contains, or which branch was taken. M4 rewrites this file into
`logs/symptom.log` by re-running the same script against the renamed build.

## Test-only infrastructure, and caveats

* `private/repro/Workload.java` is an ordinary client program (public `ZooKeeper` API
  only). It is compiled at run time and is not part of the server build.
* The samplers (`/proc/<pid>/fd`, `ss -tan`) observe the JVM from outside; they do not
  touch ZooKeeper.
* Everything runs on one host with loopback addresses, so leader election is far faster
  than in a real deployment: the observer manages ~156 retries per second, where the
  original report saw "over a million a day". The mechanism is identical; only the rate
  differs.
* The three participants are re-provisioned rather than restored from a backup. Either
  produces the same precondition (quorum behind the learner, learner with no transaction
  log); re-provisioning is deterministic and needs no epoch bookkeeping.
* CLOSE_WAIT sockets are counted per network namespace (the container), where only these
  processes run. The observer's own socket count (`/proc/<pid>/fd`) grows in lockstep,
  which is the more direct evidence.

## M4 re-run against the renamed (anonymized) build

`private/anonymize.sh` re-ran this same script against the renamed tree at the neutral path
`repos/zookeeper-ensemble-src`. The failure reproduced identically: observer snapshot
`0x100001013` vs leader zxid `0x1000003b2`, **6 058** `NullPointerException`s in 40 s (now
at `FileTxnLog.rollBack(FileTxnLog.java:381)` — same line, renamed method), 6 059
leader-side syncs with sid 4, `srvr` again "not currently serving requests", client
`connect=TIMEOUT`, observer sockets 35 → 113 and CLOSE_WAIT 0 → 32. `logs/symptom.log` =
512 839 lines / 74 MB, genuine output of the renamed binaries.

Two assertions in this script were made vocabulary-agnostic after the M3 run so that they
match either wording (`FileTxnLog.(truncate|rollBack)`, `(Truncating|Rolling back the
transaction) log to get in sync with the leader`); nothing else about the detection changed.

## M3 step 8 — merging the reproduction into the shared production log

`context/METHODOLOGY.md` §5/M3 step 8 requires the LLM-facing log to be the reproduction
**inside** the system's real production noise. The shared, read-only
`production-logs/Zookeeper/production.log` (1.5 GB, 8 052 741 records, 7-node ensemble under
YCSB + chaos monkey, 2026-08-14 18:44:25,716 → 19:28:51,007) is merged with this bug's
reproduction by `private/merge_logs.py`:

```bash
python3 private/merge_logs.py \
    --production production-logs/Zookeeper/production.log \
    --repro      private/symptom.orig.log \
    --out        private/merged.orig.log \
    --interleave position
```

* **Retime, don't rewrite.** Only each reproduction record's leading timestamp changes; it is
  linearly warped from the reproduction span (2026-08-12 18:01:31,351 → 18:02:52,935) onto the
  full production span, so the reproduction keeps its relative ordering and gaps but is spread
  across the whole production timeline. Every other character of every line — reproduction and
  production alike — is carried verbatim.
* **`--interleave position`, not `timestamp`.** The shared ZooKeeper production log is not one
  sorted timeline: it is 10 concatenated per-host sections (`zk1`…`zk7` plus rotations), each
  restarting the clock over the same ~44-minute window. A literal timestamp merge degenerates
  on such a bundle — every reproduction record is "later" than the head of each new section, so
  the whole reproduction collapses into the first section as one contiguous foreign block,
  exactly what the methodology's "spread across the production timeline" rule forbids. Position
  interleaving keeps the retiming rule and only changes the insertion key: record *k* is placed
  at production-record index *f_k × N*, so the reproduction is distributed across all ten
  sections. (`merge_logs.py` is `Zookeeper-1851`'s tool, copied unmodified, so both ZooKeeper
  bugs merge identically.)
* **Result (M3, pre-anonymization):** `private/merged.orig.log` — 8 052 741 production +
  392 149 reproduction records, 1.6 GB. The standalone `private/symptom.orig.log` is kept
  unchanged as the reference (Log A).

M4 regenerates both logs from the anonymized build: `logs/repro.log` (Log A, anonymized) and
`logs/symptom.log` (Log B, the merged log the LLM is given). Because the production log is real
ZooKeeper output, it contains the very class names and log wording M4 rewrites — so the same
substitution map is applied to the production stream *while building this bug's merged log*
(`--rename`), keeping the merged log self-consistent with `source/`. The shared production log
itself is never modified.
