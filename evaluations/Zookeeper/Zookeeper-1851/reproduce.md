# Reproduction — Zookeeper-1851

## Symptom being reproduced

A client connected to a **non-leader member** of a ZooKeeper ensemble issues a create that
asks the server to return the new node's `Stat` (the `create(path, data, acl, mode, Stat)`
overload of the client API). The call never completes; after the read timeout the client
gets a `ConnectionLoss`, the node is never created, and **every other client connected to
that same member also starts failing** — that member stops answering requests entirely,
although its process stays alive and it keeps accepting and revalidating sessions.

A plain `create(path, data, acl, mode)` on the *same* connection, moments earlier, succeeds
in 8 ms. The same create-with-stat against the leader is fine.

## How to run it

```bash
cd /mnt/SSD-4T/ycx/CLODS
docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1851 \
    -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1851/reproduce.sh'
# then merge the reproduction into the shared production log (M3 step 8):
python3 evaluations/Zookeeper/Zookeeper-1851/private/merge_logs.py \
    --production production-logs/Zookeeper/production.log \
    --repro     evaluations/Zookeeper/Zookeeper-1851/private/symptom.orig.log \
    --out       evaluations/Zookeeper/Zookeeper-1851/private/merged.orig.log
```

`REPO=` overrides the source tree and `OUT_LOG=` the destination log; M4's
`private/anonymize.sh` re-runs both steps against the renamed rebuild to produce
`logs/repro.log` and the merged `logs/symptom.log`. Exit code 0 = reproduced.

## Scenario

1. **Real 3-node ensemble**, built from the pre-fix tree (`ant jar`, ZooKeeper
   3.5.0-SNAPSHOT), started as three `QuorumPeerMain` JVMs on client ports
   24551/24552/24553 (quorum 24561-3, election 24571-3, admin 24581-3), each with the
   **root logger at DEBUG** on the console.
2. The script asks the servers themselves who leads, using the server's own `srvr`
   four-letter-word command. In the captured run: leader = `24553` (myid 3),
   followers = `24551` (myid 1) and `24552` (myid 2). **F1 = 24551** is the member the
   failing client talks to.
3. **Real client traffic** through the real APIs, concurrently:
   - `c1` — 120 iterations of create / getData / setData / exists / getChildren / delete
     against the **leader** (`/app/svc1`);
   - `c3` — the same against **follower #2** (`/app/svc3`);
   - a real **zkCli** shell session against the leader (40 × create/get/set/stat on
     `/app/cfg-*`, then 20 deletes);
   - `c2` — a second client **pinned to follower #1**, creating, reading and deleting
     ephemeral nodes every 200 ms for 45 s (`/app/svc2`).
4. **The failing operation.** An ordinary session pinned to follower #1 (`/app/svc4`):
   `create /app/svc4/entry-<n>` (plain — succeeds), then `create /app/svc4/item-9137`
   **with a `Stat` out-parameter**.
5. Afterwards a zkCli session on the leader checks whether `/app/svc4/item-9137` exists.

**Neutral naming (deliberate).** Znode paths, workload ids and the collected-file headers
carry no hint of which session fails or which call is at fault: the earlier revision used
`/app/failing/with-stat` and a `client_failing.log` header, which named both the failing
session *and* the operation inside an LLM-facing artifact. Paths are now `/app/svcN/...`,
workloads are `c1..c4`, and the collection headers follow the production log's own
`host__path` convention (`zk11__var_log_zookeeper__zookeeper.log`,
`app5__var_log_app__client.log`, …).

## What is triggered

The create-with-stat is sent as a distinct write operation from the plain create. On the
follower it enters the same request pipeline
(`FollowerRequestProcessor` → `CommitProcessor` → `FinalRequestProcessor`) but is not
handled by the pipeline's per-opcode switches, so it is never shipped to the leader and is
handed to the final processor as if it were a read, with no transaction attached. The
server's own log records the whole thing (follower myid 1); in the **anonymized** M4 build
the class names and log wording are the renamed ones (see `private/anonymization_map.json`),
and the raw pre-anonymization capture reads:

```
DEBUG [FollowerRequestProcessor:1:CommitProcessor@338] - Processing request:: ... type:create2 cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/svc4/item-9137
DEBUG [CommitProcWorkThread-2:FinalRequestProcessor@91]  - Processing request:: ... type:create2 ... zxid:0xfffffffffffffffe txntype:unknown
WARN  [CommitProcWorkThread-2:WorkerService$ScheduledWorkRequest@163] - Unexpected exception
java.lang.NullPointerException
        at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
        at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
        at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
        ...
ERROR [CommitProcWorkThread-2:CommitProcessor$CommitWorkRequest@286] - Exception thrown by downstream processor, unable to continue.
INFO  [CommitProcessor:1:CommitProcessor@191] - CommitProcessor exited loop!
```

Contrast in the same log: the *plain* create on the same session shows a
`Committing request::` line (it went to the leader and came back committed, with a real
`zxid` and `txntype:1`) before `FinalRequestProcessor` ran. The create-with-stat has no such
line — `zxid:0xfffffffffffffffe` (the "no zxid assigned" sentinel) and `txntype:unknown`.

After the processor exits its loop the follower answers nothing: sessions time out,
reconnect to the same member, get revalidated, and time out again.

## How it is detected (silent — nothing is injected into the log)

`reproduce.sh` asserts, from the clients' result files and the servers' own logs:

| assertion | observed |
|---|---|
| control plain create on the follower succeeds | `plain_create=OK elapsed_ms=8` |
| create-with-stat does **not** complete | `create_with_stat=EXCEPTION …ConnectionLossException … elapsed_ms≈6770` |
| the node was never created | leader-side check prints `Node does not exist: /app/svc4/item-9137` |
| the follower's pipeline died | the follower's log contains `unable to continue` |
| other clients on that member are hit too | `collateral_ok≈20 collateral_failed≈5`, every one a `ConnectionLossException` |

`Workload.java` **never writes to stdout or stderr** — its observations go to
`private/result_<name>.txt`, which are not part of either log. The assertion verdicts are
printed by `reproduce.sh` to its own stdout only.

## The two logs (M3 step 8)

| | file | what it is |
|---|---|---|
| **Log A** | `private/symptom.orig.log` (pre-anon) → `logs/repro.log` (anon) | the standalone reproduction: 3 server logs + 6 client session logs, **19 049 lines**. Kept for reference; **never given to the LLM**. |
| **Log B** | `private/merged.orig.log` (pre-anon) → `logs/symptom.log` (anon) | Log A merged into the shared production log — **1.5 GB, 8 068 887 lines**. This is what the LLM gets. |

The shared production log is `production-logs/Zookeeper/production.log` (1.5 GB, 8 052 741
records, ZooKeeper DEBUG under YCSB + chaos monkey, 2026-08-14 18:44–19:32). It is
**read-only and never modified** — the merge only reads it.

Findability check on the merged log: `Client session timed out` → 10 hits,
`NullPointerException` → 1, `unable to continue` → 1, i.e. the observable is reachable by a
single grep, but the surrounding 8 M lines are unrelated production traffic.

### Merge deviation, stated plainly

METHODOLOGY §5/M3 step 8 specifies a 2-way **timestamp** merge, which assumes the production
log is one globally sorted timeline. **This one is not**: it is 10 concatenated per-host
sections (`zk1`…`zk7` plus rotations), each restarting the clock over the same ~47-minute
window. A literal timestamp merge therefore degenerates — every reproduction record is
"later" than the head of each new section, so the whole reproduction collapses into the
first section as one contiguous foreign block (measured: 80 % of it inside the first 500 k of
8.07 M lines), which is exactly the outcome the methodology forbids.

`private/merge_logs.py` therefore keeps the specified **retiming** rule unchanged — linear
warp of the reproduction span onto the production span, preserving relative ordering and
relative gaps — and changes only the **interleaving key**, from timestamp to proportional
record position (`--interleave position`; `--interleave timestamp` still implements the
literal rule). The reproduction is then distributed across all 10 host sections in order
(measured spread per 1 M lines: 820 / 509 / 379 / 18 / 62 / 0 / 0 / 1512 / 93).

Consequence worth knowing: because each host section restarts the clock, an inserted
reproduction record's (warped) timestamp is not always adjacent-consistent with its
immediate neighbours' local clock. Preserving the reproduction's internal ordering and gaps
is what the methodology explicitly asks for ("so the failure sequence stays coherent and
traceable"), and the production bundle already contains non-monotonic timestamps at every
section boundary.

## Test-only infrastructure (for auditing)

- `private/repro/Workload.java` — a driver that only calls the public
  `org.apache.zookeeper.ZooKeeper` client API (`create`, `getData`, `setData`, `exists`,
  `getChildren`, `delete`, and the `create(..., Stat)` overload). It reports what it
  observed to a result file so that nothing it says can leak into either log. It adds no
  instrumentation to ZooKeeper and reads no internal state.
- `private/merge_logs.py` — the M3 step-8 merge (read-only on the shared production log).
- Three dependency edits to the 2014 build files (`private/deps-fix.patch`) so the tree
  compiles on a modern toolchain. No production source was changed at M3.
- Distinct admin (Jetty) ports per member, because three members share one host here.

## Caveats

- All three members and all clients run in one container on loopback, not on separate
  production hosts. This affects timing only.
- The ensemble has no *observer* member, so only the follower variant of the defect is
  exercised at run time (the observer request processor contains the identical switch).
- The merged log mixes two ZooKeeper builds: the production sections come from a different
  version than `source/`, so production lines carry different `Class@line` numbers than the
  reproduction lines. That is inherent to merging one shared production log into every bug.
- Session timeout is 10 s, so the client's `ConnectionLoss` arrives after ~6.8 s (the
  client's read timeout is 2/3 of the session timeout). Nothing else was tuned.
