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
```

`REPO=` overrides the source tree and `OUT_LOG=` the destination log; M4's
`private/anonymize.sh` re-runs this same script against the renamed rebuild to produce
`logs/symptom.log`. Exit code 0 = reproduced, 1 = not reproduced.

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
   - `Workload normal` — 120 iterations of create / getData / setData / exists /
     getChildren / delete against the **leader**;
   - `Workload normal` — the same against **follower #2**;
   - a real **zkCli** shell session against the leader (40 × create/get/set/stat, then 20
     deletes);
   - `Workload collateral` — a second client **pinned to follower #1**, creating,
     reading and deleting ephemeral nodes every 200 ms for 45 s.
4. **The failing operation.** An ordinary session pinned to follower #1:
   `create /app/failing/control-<n>` (plain — succeeds), then
   `create /app/failing/with-stat` **with a `Stat` out-parameter**.
5. Afterwards a zkCli session on the leader checks whether `/app/failing/with-stat` exists.

## What is triggered

The create-with-stat is sent as a distinct write operation from the plain create. On the
follower it enters the same request pipeline
(`FollowerRequestProcessor` → `CommitProcessor` → `FinalRequestProcessor`) but is not
handled by the pipeline's per-opcode switches, so it is never shipped to the leader and is
handed to the final processor as if it were a read, with no transaction attached. The
server's own log records the whole thing (`server_1.log`, myid 1):

```
DEBUG [FollowerRequestProcessor:1:CommitProcessor@338] - Processing request:: sessionid:0x19ff3a0dfd10001 type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/failing/with-stat
DEBUG [CommitProcWorkThread-2:FinalRequestProcessor@91]  - Processing request:: sessionid:0x19ff3a0dfd10001 type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown reqpath:/app/failing/with-stat
WARN  [CommitProcWorkThread-2:WorkerService$ScheduledWorkRequest@163] - Unexpected exception
java.lang.NullPointerException
        at org.apache.zookeeper.server.ZKDatabase.addCommittedProposal(ZKDatabase.java:251)
        at org.apache.zookeeper.server.FinalRequestProcessor.processRequest(FinalRequestProcessor.java:127)
        at org.apache.zookeeper.server.quorum.CommitProcessor$CommitWorkRequest.doWork(CommitProcessor.java:294)
        at org.apache.zookeeper.server.WorkerService$ScheduledWorkRequest.run(WorkerService.java:161)
        ...
ERROR [CommitProcWorkThread-2:CommitProcessor$CommitWorkRequest@286] - Exception thrown by downstream processor, unable to continue.
INFO  [CommitProcessor:1:CommitProcessor@191] - CommitProcessor exited loop!
```

(`type:createExt` is the M4-renamed name of the opcode — see `private/anonymization_map.json`.)

Contrast in the same log, three lines earlier: the *plain* create on the same session shows
a `Committing request::` line (it went to the leader and came back committed, with a real
`zxid` and `txntype:1`) before `FinalRequestProcessor` ran. The create-with-stat has no such line —
`zxid:0xfffffffffffffffe` (the "no zxid assigned" sentinel) and `txntype:unknown`.

After `CommitProcessor exited loop!` the follower answers nothing: sessions time out,
reconnect to the same member, get revalidated, and time out again.

## How it is detected (silent — nothing is injected into the log)

`reproduce.sh` asserts, from the clients' result files and the servers' own logs:

| assertion | observed |
|---|---|
| control plain create on the follower succeeds | `plain_create=OK elapsed_ms=8` |
| create-with-stat does **not** complete | `create_with_stat=EXCEPTION org.apache.zookeeper.KeeperException$ConnectionLossException ... elapsed_ms=6772` |
| the node was never created | leader-side check prints `Node does not exist: /app/failing/with-stat` |
| the follower's pipeline died | `server_1.log` contains `unable to continue` |
| other clients on that member are hit too | `collateral_ok=20 collateral_failed=5`, every one a `ConnectionLossException` |

`Workload.java` **never writes to stdout or stderr** — its observations go to
`private/result_<name>.txt`, which are not part of the symptom log. The assertion verdicts
are printed by `reproduce.sh` to its own stdout only.

## The captured log

- Path: `logs/symptom.log` (the M4 run, from the renamed build) — **19 014 lines**, 15 618
  `DEBUG`. `private/symptom.orig.log` is the equivalent pre-anonymization capture
  (19 009 lines). Both are gitignored and regenerable.
- Contents: `server_1.log`, `server_2.log`, `server_3.log` (all three members' own DEBUG
  output) followed by the six client session logs (`client_leaderwl`, `client_followerwl`,
  `client_shell`, `client_collateral`, `client_failing`, `client_check`) — the ZooKeeper
  **client library's** own DEBUG output for each JVM.
- The only text not produced by ZooKeeper is one `===== file: X =====` header per collected
  file.
- **No log or print statement was added anywhere** — not to the server, not to the client
  library, not to the driver. The stack trace above is the JVM/WorkerService's own report.

## Test-only infrastructure (for auditing)

- `private/repro/Workload.java` — a driver that only calls the public
  `org.apache.zookeeper.ZooKeeper` client API (`create`, `getData`, `setData`, `exists`,
  `getChildren`, `delete`, and the `create(..., Stat)` overload). It reports what it
  observed to a result file so that nothing it says can leak into the symptom log. It adds
  no instrumentation to ZooKeeper and reads no internal state.
- Three dependency edits to the 2014 build files (`private/deps-fix.patch`) so the tree
  compiles on a modern toolchain — dead Maven repositories and `javac` source/target 1.5 →
  1.8. No production source was changed.
- Distinct admin (Jetty) ports per member, because three members share one host here.

## Caveats

- All three members and all clients run in one container on loopback, not on separate
  production hosts. This affects timing only: the failure is a per-member request-pipeline
  defect and does not depend on the network.
- The ensemble has no *observer* member, so only the follower variant of the defect is
  exercised at run time (the observer request processor contains the identical switch).
- Session timeout is 10 s, so the client's `ConnectionLoss` arrives after ~6.8 s (the
  client's read timeout is 2/3 of the session timeout). Nothing else was tuned.
