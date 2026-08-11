# Reproduction — Zookeeper-1434

**Bug (one line).** The ZooKeeper command-line shell (`zkCli`) dies with an **unhandled
`NullPointerException`** when an operator asks for the status of a znode that does not
exist; every other command reports a missing node gracefully ("Node does not exist: …").

**Tree under test.** `apache/zookeeper` @ `59ac9fa78963ca746d21a62a27fde497fd4c4d58`
(trunk, 2011-05, 3.4.0-dev) — the commit **immediately before** the fix
`7f64942ba` (ZOOKEEPER-1059), built from source with `ant jar` (see PROGRESS.md M2).

## How to run it

```bash
cd /mnt/SSD-4T/ycx/CLODS
docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1434 \
    -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1434/reproduce.sh'
```

Runtime ≈ 40 s. Exit code 0 = reproduced. Environment knobs (used by M4 on the anonymized
tree): `MAIN_CLASS` (CLI entry class), `STAT_CMD` (name of the node-status command),
`PORT`, `REPO`, `BUG_DIR`.

## Scenario

A real, single-node ZooKeeper **server** is started from the build
(`org.apache.zookeeper.server.quorum.QuorumPeerMain`, which falls back to standalone mode),
with the root logger and the console appender both at **DEBUG**
(`-Dzookeeper.root.logger=DEBUG,CONSOLE -Dzookeeper.console.threshold=DEBUG`).

Four **real** `zkCli` sessions then talk to it — the real shell class, real RPCs, no test
harness, no mocks:

| Session | Traffic |
|---|---|
| A  | builds `/app`, `/app/workers/w1..w60`, `/app/config/key1..key20`: ~340 `create`/`get`/`set`/status/`getAcl`/`ls`/`ls2`/`delete` operations, then `quit` |
| A2 | the same workload replayed, **concurrently with B** (re-creates + updates the same nodes) |
| B  | a second client cycling `create`/status/`get`/`delete` over `/app/locks/lock-1..40`, then `quit` |
| C  | an ordinary admin session: `ls /`, `ls /app`, status of `/app`, `get`+status of `/app/config/key1`, `ls /app/workers`, status of the **existing** `/app/workers/w42` — and finally the status of **`/app/workers/w4242`, which does not exist** |

Commands are fed to the shell on stdin, so it runs in its normal interactive loop
(`main → run → executeLine → processCmd → processZKCmd`), exactly as in an operator
session.

## Trigger

Session C's last command asks for the status of a path that was never created. That is the
only command in the whole workload whose handler calls `ZooKeeper.exists(path, watch)`,
whose contract is to **return `null`** (rather than throw) when the znode is absent. The
server answers the request normally — the DEBUG line right before the crash shows the
reply carrying error code `-101` (`NoNode`) and an empty response body:

```
[main:ZooKeeperMain@618] - Processing stat
[...ClientCnxn$SendThread@725] - Reading reply sessionid:0x…, packet:: … header:: 8,3
    replyHeader:: 8,415,-101  request:: '/app/workers/w4242,F  response::
Exception in thread "main" java.lang.NullPointerException
	at org.apache.zookeeper.ZooKeeperMain.printStat(ZooKeeperMain.java:132)
	at org.apache.zookeeper.ZooKeeperMain.processZKCmd(ZooKeeperMain.java:727)
	at org.apache.zookeeper.ZooKeeperMain.processCmd(ZooKeeperMain.java:583)
	at org.apache.zookeeper.ZooKeeperMain.executeLine(ZooKeeperMain.java:355)
	at org.apache.zookeeper.ZooKeeperMain.run(ZooKeeperMain.java:313)
	at org.apache.zookeeper.ZooKeeperMain.main(ZooKeeperMain.java:272)
```

This is byte-for-byte the frame sequence quoted in the JIRA report (only the line numbers
differ, because the report is against 3.3.5 and this tree is 3.4.0-dev).

## Detection (silent — nothing written into the symptom log)

`reproduce.sh` asserts three things, all by reading the system's own output, and prints the
verdict to **its own stdout**, never into the log:

1. session C's JVM exit code is non-zero — observed **1** (expected 0 for a clean `quit`);
2. session C's output contains `Exception in thread "main" java.lang.NullPointerException`;
3. session C's output does **not** contain `Node does not exist:` — i.e. the shell did not
   take the graceful path it takes for every other command against a missing node.

Observed vs expected: the shell **terminated with an uncaught NPE (exit 1)** where the
expected behaviour is to print `Node does not exist: /app/workers/w4242` and keep the
session alive (that is precisely what the later ZooKeeper releases do, and what the
remaining `ls /app/config` + `quit` lines in session C never got to prove).

## The captured log

- Path: `private/symptom.orig.log` (pre-anonymization) → `logs/symptom.log` (M4).
- Size: **9 555 lines**, of which **3 147 DEBUG** and 191 INFO — the server's own
  request-processor / session / snapshot tracing plus every client's per-request
  `Reading reply … request:: … response:: …` DEBUG lines.
- Content: the concatenation, in start order, of the five log files the run produced —
  `server.log`, `client_A.log`, `client_A2.log`, `client_B.log`, `client_C.log`. The
  **only** text `reproduce.sh` adds is one `===== file: <name> =====` collection header per
  file, so a reader can tell which process each block came from. There are **no injected
  log lines, no `System.out.println`, no probes, and no markers that reveal internal
  state** — the NPE trace is the JVM's own uncaught-exception report.

## Test-only infrastructure

**None.** No production file was modified for the reproduction; no test class was written.
The only non-pristine element is the *deployment* configuration: a generated `zoo.cfg`
(tickTime/dataDir/clientPort) and the two DEBUG logging system properties, both of which
are ordinary operator settings.

The build-file changes needed to compile a 2011 Ant/Ivy tree on a modern toolchain are in
`private/deps-fix.patch` (dead Maven mirrors → Central over HTTPS; `javac.target` 1.5 → 1.8).
They touch `build.xml` / `ivysettings.xml` only — never source.

## Caveats

- Single-node (standalone) server on loopback inside a container, not a multi-node
  production ensemble. The defect is entirely client-side, so quorum plays no role; the
  ensemble would only change which server answers the `exists` request.
- The workload is a synthetic-but-real operator/worker traffic mix driven through the real
  CLI (≈900 client operations across four sessions) rather than a standard benchmark such
  as YCSB, for which this 2011 tree has no binding.
- Log timestamps are the container's clock (the host is set to 2026); the ZooKeeper
  version string in the log is `3.4.0--1` because the tree is built from a detached
  checkout without an SVN revision.
