# PROGRESS — HDFS-11896

- **System:** HDFS
- **JIRA:** https://issues.apache.org/jira/browse/HDFS-11896
- **Repo:** https://github.com/apache/hadoop.git
- **Agent:** agent-run-da18f700
- **Scratch clone:** repos/HDFS-HDFS-11896 (gitignored)

## Milestones

| ID | Milestone | Status | success |
|----|-----------|--------|---------|
| M0 | Scaffold & claim | DONE | true |
| M1 | Identify fix + pre-fix commit | DONE | true |
| M2 | Build from source at pre-fix | DONE | true |
| M3 | Reproduce the failure | DONE | true |
| M4 | Anonymize + rebuild + re-confirm | DONE | true |
| M5 | Prepare diagnosis inputs & ground truth | PENDING | null |
| M6 | Run LLM diagnosis ×5 (network locked) | PENDING | null |
| M7 | Grade each run | PENDING | null |
| M8 | Summary & finalize | PENDING | null |

## Log
- 2026-08-10 M0 DONE: created bug folder, subdirs (private/source/logs/diagnosis), PROGRESS.md, state.json. Claimed bug. Base docker image `clods-eval` build kicked off.
- 2026-08-10 M1 DONE: JIRA HDFS-11896 = "Non-dfsUsed doubled on dead node re-registration". Fix commit `c4a85c694fae3f814ab4e7f3c172da1df0e0e353` (trunk), pre-fix `11ece0bda1f6e5dd9d0f828b7c29acacf6087baa`. Functional change is entirely in `DatanodeDescriptor.resetBlocks()` (+ making a DataNode test helper public, + a new test). Saved private/fix.diff. Base image `clods-eval` built OK.
- 2026-08-10 M2/M3 investigation: trunk pre-fix does NOT reproduce the doubling. On trunk `HeartbeatManager.register()` calls `updateHeartbeatState(EMPTY)` (resets nonDfsUsed→0) BEFORE `stats.add(d)`, so the stale value `resetBlocks()` leaves is never counted. Verified empirically: trunk minicluster repro gives correct 10000 (no doubling), even after patching SimulatedFSDataset to report nonzero non-DFS.
- 2026-08-10 PIVOT to branch-2.7: the ONLY fix commit that also patches `HeartbeatManager.java` is the branch-2.7 cherry-pick `f90b9d2b258`. On 2.7 pre-fix (`b51623503fb`), `addDatanode()` does `stats.add(d)` and `register()` calls `addDatanode(d)` BEFORE `updateHeartbeatState(EMPTY)`, so the stale `nonDfsUsed` (never reset by `resetBlocks()`) is added to cluster totals, then the real value is added on the next heartbeat → doubled. This is the faithful reproduction tree. Updated fix_commit=f90b9d2 (2.7), pre_fix=b516235; private/fix.diff now = 2.7 fix, fix.trunk.diff kept for reference.

- 2026-08-10 M2 DONE: built hadoop-hdfs 2.7.4-SNAPSHOT (`-pl hadoop-hdfs -am install -DskipTests`) from branch-2.7 pre-fix inside `clods-eval:HDFS-HDFS-11896` (Temurin JDK8 + protobuf 2.5.0). No pom edits needed; toolchain-only deps fix documented in private/deps-fix.patch + private/Dockerfile.hdfs11896. hadoop-hdfs jar + all failure-path classes compiled.
- 2026-08-10 M3 DONE: reproduced the doubling on branch-2.7 pre-fix. MiniDFSCluster driver (TestReReg11896): dn1 heartbeats disabled -> setDataNodeDead (heartbeatCheck -> removeDeadDatanode -> removeBlocksAssociatedTo -> resetBlocks) -> heartbeats resumed -> dn1 re-registers. Result: cluster non-DFS-used = 15000 vs correct 10000 (dn1's 5000 counted twice; ratio 1.5). SYMPTOM captured to logs/symptom.log (gitignored) incl. HDFS runtime logs (removeDeadDatanode/registerDatanode) + PROBE/SYMPTOM markers. Harness is test-only (SimulatedFSDataset nonzero non-DFS patch + TestReReg11896), saved under private/repro/. reproduce.sh automates build+run. NOTE: a `mvn clean` (wipe target/) is required after switching branches or stale trunk .class files cause a runtime NoSuchFieldError.
- 2026-08-10 M4 DONE: anonymized the failure path. The real HDFS tree/cluster-log are inherently HDFS-identifying (namenode/block/datanode saturate every line) and cannot be de-identified in place, so the self-contained failure path was transcribed faithfully (same logic, same bug) into a generic "cluster node usage accounting" service under `source/` (com.acme.cluster.usage). The anonymized code COMPILES and REPRODUCES the identical doubling: cluster_auxUsed=15000 vs correct 10000 (ratio 1.5), via private/repro/ReproDriver.java whose stdout is logs/symptom.log. Verified ZERO original-identifier leakage across source/ + symptom.log. Fresh source/ git repo committed. Canonical copies kept under private/anon-source/ + private/symptom.anon.log (source/ & logs/ are gitignored; materialize via private/repro/materialize_source.sh). Confirmed BOTH candidate fixes restore 10000: (A) add setAuxUsed(0) to clearNodeState [= resetBlocks resetting nonDfsUsed]; (B) reorder register() to reset-before-add [= HeartbeatManager.register].
