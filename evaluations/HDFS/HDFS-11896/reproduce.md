# Reproduction — HDFS-11896

"Non-dfsUsed will be doubled on dead node re-registration."
Reproduced on the **branch-2.7 pre-fix** tree (`b51623503fbd71b88647c175a79470d19b11d907`,
Hadoop `2.7.4-SNAPSHOT`). The symptom is a **wrong metric**, not a crash or an error log:
the NameNode's cluster non-DFS-used total is inflated by one node's worth after a DataNode
dies and re-registers.

## How to run

From the repo root, inside the per-bug image (repo mounted at `/work`):

```bash
docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:HDFS-HDFS-11896 \
    -lc 'bash /work/evaluations/HDFS/HDFS-11896/reproduce.sh'
```

`reproduce.sh` (a) clean-builds `hadoop-hdfs` + deps at the pre-fix commit
(Temurin JDK 8 + protobuf 2.5.0), (b) runs the driver test with verbose logging, (c) writes
the raw system log to `private/symptom.orig.log`, then (d) calls `private/anonymize.sh` to
produce the LLM-facing `source/` + `logs/symptom.log` (JIRA-id scrub + `nonDfsUsed→otherUsed`).

## Scenario (driver: `private/repro/TestReReg11896.java`)

A single-JVM `MiniDFSCluster`, 2 DataNodes, 4 MB simulated capacity each:

1. **Verbose logging on** — the failure-path packages (`blockmanagement`, `datanode`,
   `namenode`, `StateChange`, `BlockStateChange`) are set to **DEBUG** at test start.
2. **Normal operations** — write and read back three 64 KB files (`/user/app/data-0..2.bin`,
   4 KB blocks, replication 2). This generates real block-allocation, block-report,
   replication and heartbeat activity in the log.
3. **Trigger** — disable dn1's heartbeats and `cluster.setDataNodeDead(dn1)`. This drives the
   real NameNode path: `heartbeatCheck → removeDeadDatanode → removeDatanode →`
   `BlockManager.removeBlocksAssociatedTo → DatanodeDescriptor.resetBlocks()`.
4. **Re-register** — re-enable dn1's heartbeats; dn1 re-registers via the "node restarted"
   path (`registerDatanode → HeartbeatManager.register → addDatanode`) and resumes
   heartbeating.
5. **Detect (silently)** — assert the NameNode metric equals the sum over live nodes:
   `assertEquals(dn1.getNonDfsUsed() + dn2.getNonDfsUsed(), ns.getNonDfsUsedSpace())`.

## What reproduction looks like

The assertion **fails** on the buggy tree:

```
cluster non-DFS-used must equal sum of live datanodes  expected:<2097152> but was:<3145728>
```

i.e. true total **2 MB** (2×1 MB), observed **3 MB** — dn1's 1 MB non-DFS is counted twice.
Capacity and DFS-used totals stay correct; only non-DFS-used is wrong, and it stays wrong.

**This assertion output is used only to confirm reproduction; it is NOT written into the
symptom log.**

## The captured log (what the diagnosis LLM sees)

- `logs/symptom.log` — **4578 lines** (3588 DEBUG + 888 INFO), the NameNode/DataNode's own
  DEBUG output across the whole scenario. It contains only the system's timestamped log lines
  (Maven/Surefire noise and the assertion are excluded). **No injected / answer-revealing
  lines** (no `PROBE`, no metric dumps, no "this is wrong").
- The failure window is real, e.g.:
  ```
  ...DatanodeManager.removeDeadDatanode - BLOCK* removeDeadDatanode: lost heartbeat from 127.0.0.1:44383   (line 4315)
  ...DatanodeManager.registerDatanode   - BLOCK* registerDatanode: ... node restarted.                     (line 4468)
  ```
- The wrong metric value is a JMX value (`getNonDfsUsedSpace`) that appears in **no** log line,
  so the observable symptom (~3 MB vs ~2 MB) is stated in `symptom.md` — the mechanism is not.

## Test-only infrastructure (not the pristine production path — disclosed for audit)

- **`SimulatedFSDataset`** is patched to report a nonzero, deterministic non-DFS-used value
  (`getCapacity()/4` = 1 MB) instead of the upstream hardcoded `0L`. Without this the metric
  is vacuously 0 and the doubling is unobservable (this is also why upstream's own test does
  not actually catch the bug). This is a *data* change, not a log statement.
- **Reflection** is used to toggle `DataNode.setHeartbeatsDisabledForTests(...)` (package-
  private on the pre-fix tree) so no production source is edited.
- Small block size (4 KB) + 4 MB simulated capacity so the real writes have valid placement
  targets on the simulated volumes.

## Caveats

- This is a **`MiniDFSCluster`** reproduction (single JVM, simulated storage), not a full
  multi-daemon production cluster — the practical trade-off for a deterministic, controllable
  repro. The failure path exercised is the real NameNode block-management code.
- Trunk / branch-2.8 / branch-2.9 pre-fix do **not** reproduce this (their `register()`
  already resets before adding); the bug manifests on **branch-2.7**, which is why that tree
  was chosen. See `PROGRESS.md` / `private/ground_truth.md`.
