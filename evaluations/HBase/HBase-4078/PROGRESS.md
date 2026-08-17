# HBase-4078 — milestone tracker

| Field | Value |
|---|---|
| bug id | HBase-4078 |
| system | HBase |
| jira | https://issues.apache.org/jira/browse/HBASE-4078 |
| source repo | https://github.com/apache/hbase.git |
| fix commit | `df9b82c082571b7dfca4380bffaa38f3fd058927` (trunk, svn@1183071, 2011-10-13) |
| pre-fix commit | `9814ffbaf0eca469bbded025a1dca81271c6d4e6` (0.93-SNAPSHOT) |
| owner | agent-run-4ee9c5a7 |

## Milestones

| ID | Milestone | Status | success | outcome | note |
|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | true | success | folder + trackers created |
| M1 | Identify fix + pre-fix commit | DONE | true | success | `Store.validateStoreFile` added at 2 promotion sites |
| M2 | Build from source at pre-fix | DONE | true | success | mvn package, JDK 8, hadoop 1.0.4 |
| M3 | Reproduce + merge into production log | IN_PROGRESS | null | in_progress | harness written + committed; run blocked (sandbox refuses `docker`) |
| M4 | Anonymize failure path, rebuild, re-reproduce | PENDING | null | pending | |
| M5 | Diagnosis inputs + ground truth | PENDING | null | pending | |
| M6 | LLM diagnosis ×5 | PENDING | null | pending | |
| M7 | Grade runs | PENDING | null | pending | |
| M8 | Summary & finalize | PENDING | null | pending | |

## Log

- 2026-08-17T01:52:58Z agent-run-4ee9c5a7 — claimed HBase-4078; created `evaluations/HBase/HBase-4078/{private,source,logs,diagnosis}`; wrote PROGRESS.md + state.json. First HBase bug in this workspace (`production-logs/HBase/production.log` exists, 3.06 GB, HBase 1.2.7 under YCSB+chaos monkey — so the M3 merge applies).
- 2026-08-17T02:20:00Z agent-run-4ee9c5a7 — M1 DONE. HBASE-4078 "Silent Data Offlining During HDFS Flakiness". Fix commit `df9b82c082` (trunk) = "HBASE-4078 Validate store files after flush/compaction"; saved as `private/fix.diff`. Companion 0.89-fb commit `790feddf2d` saved as `private/fix.0.89.diff` (its message spells out the operator-visible symptom). Pre-fix = `9814ffbaf0`.

  **The fix**: adds `Store.validateStoreFile(Path)` — open the just-written file (`new StoreFile(...).createReader()`), `LOG.error(...) + throw` on `IOException`, `closeReader()` in `finally` — and calls it at exactly **two** production sites, each **before** the file leaves the region `.tmp` dir:
  1. `Store.internalFlushCache` — before `fs.rename(writer.getPath(), dstPath)` promotes the flushed file into the store home dir;
  2. `Store.completeCompaction` — before `StoreFile.rename(...)` promotes the compaction output.

  **Pre-fix (the bug)**, verified in `9814ffbaf0:src/main/java/org/apache/hadoop/hbase/regionserver/Store.java`:
  - `internalFlushCache` 521-533: rename into the live store dir happens first, `sf.createReader()` only afterwards;
  - `completeCompaction` 1221-1232: `if (compactedFile != null)` → `StoreFile.rename(...)` into the store dir first, `result.createReader()` afterwards;
  - `loadStoreFiles` 269-279 (the HBASE-1436 workaround the ticket names): `catch (IOException ioe) { LOG.warn("Failed open of " + p + "; presumption is that file was corrupted at flush and lost edits picked up by commit log replay. Verify!", ioe); continue; }` — so at every later region open the promoted unreadable file is silently skipped.

  Ticket quotes **no** log/stack snippet, so M4's log-literal rewrite is driven by the failure-path literals themselves.
- 2026-08-17T02:12:00Z agent-run-4ee9c5a7 — M2 DONE. Pre-fix tree builds from source in `clods-eval:HBase-HBase-4078` (base image + `openjdk-8-jdk`; the pom pins `compileSource=1.6`, which JDK 11/17 refuse).
  Build: `mvn -DskipTests -B package` → `target/hbase-0.93-SNAPSHOT.jar` (3.0 MB), `-tests.jar` (1.4 MB), `target/classes`; then `mvn -B dependency:copy-dependencies -DincludeScope=test -DoutputDirectory=target/lib` → 62 jars (hadoop-core-1.0.4, hadoop-test-1.0.4, zookeeper-3.3.3), so M3 can run a real multi-JVM HDFS+HBase deployment out of this tree.
  Dependency fixes (`private/deps-fix.patch`):
  1. `pom.xml`: `hadoop.version` `0.20-append-r1057313` → `1.0.4` (the 0.20-append build only ever existed on `people.apache.org/~rawson/repo`, now gone; 1.0.4 is its published descendant).
  2. `pom.xml`: dropped the four dead 2011 repositories (`people.apache.org/~rawson/repo`, `download.java.net`, `repository.codehaus.org` — no longer resolves, and Maven aborts hard on it — `repository.jboss.org`).
  3. two javac-8 source incompatibilities **off** the failure path: `util/PoolMap.java` `remove(K,V)` → `remove(Object,Object)` (Java 8 added `Map.remove(Object,Object)`; erasure clash), and `mapreduce/hadoopbackport/InputSampler.java:344` `(K[])` cast.
- 2026-08-17T02:30:00Z agent-run-4ee9c5a7 — M3 **harness written and committed; the run itself was not executed**. This session was blocked from executing *any* `docker` command (and any large scan of the shared production log) by the sandbox safety classifier — "Auto mode could not evaluate this action … it will keep firing for the rest of this conversation". METHODOLOGY §11 requires build/reproduce to run in a container, never on bare metal, so M3 stays `IN_PROGRESS` rather than `FAILED`: nothing about the bug, the build or the harness is broken — only command execution in this session is.

  **To resume — one command from the repo root:**
  ```bash
  docker run --rm -v "$PWD:/work" -v hbase4078-m2:/root/.m2 \
    --entrypoint bash clods-eval:HBase-HBase-4078 /work/evaluations/HBase/HBase-4078/reproduce.sh
  ```
  The per-bug image (`clods-eval` + `openjdk-8-jdk`) is already built and the maven cache volume `hbase4078-m2` already holds every dependency; the only network need is the one-off Hadoop 1.0.4 tarball fetch.

  **What the harness does** (committed: `reproduce.sh`, `private/repro/DistributedFileSystemImpl.java`, `private/repro/Client.java`, `private/merge_logs.py`):
  - **Deployment** — real HDFS 1.0.4 (NameNode + 2 DataNodes) as `hbase.rootdir`, then ZooKeeper (`HQuorumPeer`), `HMaster` and **two** `HRegionServer`s as separate JVMs built from the pre-fix tree; root logger `DEBUG`; log layout `%d{ISO8601} %-5p [%t] %c: %m%n` (the shared production log's own layout); table `usertable`, family `cf`, YCSB-shaped row keys, so the reproduction and the production noise read alike.
  - **Phase A** — 36k rows in 4 batches with an operator `flush` after each, then a 4-thread mixed read/update/scan/delete workload → several genuine store files.
  - **Phase B (the incident)** — a marker file opens a bounded window in which `fs.hdfs.impl` = `DistributedFileSystemImpl`, a `DistributedFileSystem` **subclass** (so no HBase source is modified and no log/print statement is added anywhere), loses the tail of any file created under a region's `.tmp` — exactly the ticket's "partially-written files … in TMP when a FS error occurs". Ordinary traffic keeps running and both store-file-producing operations happen inside the window (an operator major compaction and an operator flush), so **both** root-cause sites are exercised: `completeCompaction` and `internalFlushCache` each promote a short file into the live store directory before ever opening it.
  - **Phase C** — the window closes and the region is opened again (regionserver restart if one aborted, then two operator `move`s): this is where `loadStoreFiles`' `catch (IOException) { … continue; }` silently skips the promoted unreadable files — "this keeps happening as the region moves around".
  - **Detection is silent** — HDFS listings, the servers' own logs and client row counts, printed only to `reproduce.sh` stdout.
  - **Logs** — Log A `private/symptom.orig.log` (per-daemon sections with `===== <name>__var_log_hbase__<file> =====` headers, matching the production log's bundle format); Log B `private/merged.orig.log` via `private/merge_logs.py` (Zookeeper-1851's tool copied verbatim; `--interleave position`, since the HBase production log is likewise a bundle of per-host sections).
