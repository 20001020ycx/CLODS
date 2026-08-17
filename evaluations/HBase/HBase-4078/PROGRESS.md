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
| M3 | Reproduce + merge into production log | DONE | true | success | 4 short files promoted into the live store dir; 139.7 MB repro log merged into 3.19 GB |
| M4 | Anonymize failure path, rebuild, re-reproduce | DONE | true | success | `Store`→`FamilyStore` + 17 log literals; both logs regenerated; gate clean |
| M5 | Diagnosis inputs + ground truth | DONE | true | success | bare-observable symptom + two-site answer key |
| M6 | LLM diagnosis ×5 | IN_PROGRESS | null | in_progress | 2/5 done; runs 3-5 blocked by the gateway's daily quota (resets 2026-08-18 08:00 EDT) |
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
- 2026-08-17T18:52:00Z agent-run-4ee9c5a7 — **M3 DONE (`success=true`)**. The harness ran end to end (3rd attempt; the first two failed on harness bugs, not on HBase — see below). Full write-up in `reproduce.md`.

  **What reproduced.** Phase A built four healthy store files (9 956 120 B each, 36 000 rows, mixed workload 36 988 ops / 0 failures). Inside the bounded filesystem-incident window an operator major compaction wrote `.tmp/65629880766638568` (39 822 970 B) which the filesystem cut to 21 902 633 B, and memstore flushes were cut the same way (8 427 637→4 635 200; two 8 361 349→4 598 741 during the region open that followed). **The pre-fix code moved every one of those short files out of `.tmp` into the region's live `cf/` directory and only then opened it** — `.tmp` ends empty, `cf/` ends holding four unreadable files beside the one healthy 44 952 978 B file (assertions 1 + 2 ok).

  **How it surfaced, in the cluster's own log:**
  - `ERROR … compactions.CompactionRequest: Compaction failed regionName=usertable,…` — the compaction died *after* its output was already in the store directory;
  - `FATAL [regionserver60021.cacheFlusher] … HRegionServer: ABORTING region server …: Replay of HLog required. Forcing server shutdown` — same for the flush;
  - **17×** `WARN … regionserver.Store: Failed open of hdfs://…/cf/<file>; presumption is that file was corrupted at flush and lost edits picked up by commit log replay. Verify!`, each carrying `java.io.IOException: java.lang.IllegalArgumentException: Invalid HFile version: 1886087525 (expected to be between 1 and 2)` at `FixedFileTrailer.readFromStream:306 ← HFile.pickReaderVersion:330 ← HFile.createReader:346 ← StoreFile$Reader.<init>:983 ← StoreFile.open:444`;
  - **2×** `ERROR … handler.OpenRegionHandler: Failed open of region=usertable,…` with `DroppedSnapshotException` from `HRegion.replayRecoveredEditsIfAny:2217`;
  - the files are never cleaned up and are silently skipped at every later open — the 0.89-fb commit's *"this keeps happening as the region moves around"*, exercised by two operator `move`s in phase C. The cluster kept serving throughout (0 client failures).

  A final scan returns 40 990 rows where 42 000 keys were written; that shortfall is recorded as an **observation only** (WAL-tail loss during log splitting on Hadoop 1.0.4 could explain part of it). Detection stays silent: HDFS listings, the servers' own logs and client row counts, printed only to `reproduce.sh` stdout.

  **Logs.** Log A `private/symptom.orig.log` = 139.7 MB / 790 805 lines (785 597 DEBUG, 1 307 INFO, 46 WARN, 7 ERROR, 2 FATAL) in four `===== <name>__var_log_hbase__<file> =====` sections. Log B `private/merged.orig.log` = 3.19 GB = 11 945 370 production + 786 959 reproduction records via `private/merge_logs.py` (Zookeeper-1851's tool, verbatim), reproduction timestamps warped from `18:43:33,544…18:48:40,160` onto the production span `2026-08-14 19:06:45,717…19:31:38,751`, `--interleave position` (the shared HBase production log is a bundle of per-host sections). The shared production log is never modified.

  **Harness bugs fixed along the way** (neither is an HBase bug): `loseTail` called the 2-arg `super.create`, which `FileSystem` dispatches back into the overridden 7-arg `create` → infinite recursion/`StackOverflowError`; and an unscoped, unbounded incident also cut short `.META.`'s open-time flushes, putting `.META.` into a retry storm — the fault is now scoped to `/usertable/` and capped at 2 files per regionserver JVM.
- 2026-08-17T19:30:00Z agent-run-4ee9c5a7 — **M4 DONE (`success=true`)**. Failure path anonymized, tree rebuilt, both logs regenerated from the anonymized build.
  - **(a) bug-id scrub** — `HBASE-4078` appears nowhere. The only Apache JIRA id in the failure-path source was a *comment* in `loadStoreFiles` (`… (upgrade, etc.): HBASE-646`); it is rewritten away.
  - **(b) distinctive term** — none exists pre-fix: the term a reader would grep (`validateStoreFile`) is introduced *by* the fix.
  - **(c) type/method renames** — `Store` → **`FamilyStore`** (`Store.java` → `FamilyStore.java`): it holds *both* root-cause sites *and* the symptom site and is the logger name on every failure-path line. Plus the case-identifying method names `internalFlushCache`→`writeSnapshotFile`, `completeCompaction`→`installCompactionResult`, `loadStoreFiles`→`openStoreFiles`, `compactStore`→`mergeStoreFiles`, and `HStore`→`FamilyStore` (the class's historical name, left in javadoc). **Kept generic** (no case-identifying value, and all present verbatim in the production log): `StoreFile(.Reader)`, `StoreFlusher`, `HRegion`, `HRegionServer`, `MemStoreFlusher`, `CompactSplitThread`, `CompactionRequest`, `OpenRegionHandler`, `HFile`, `HFileReaderV2`, `FixedFileTrailer`, `DroppedSnapshotException`.
  - **(d) log-statement rewrites** — 17 entries; the ticket quotes no log text, so the whole failure-path literal set was rewritten. Notably the symptom line `Failed open of X; presumption is that file was corrupted at flush and lost edits picked up by commit log replay. Verify!` → `Cannot read X; leaving it out of this column family's file list. Check the file.`, plus `Renaming flushed file at`→`Moving new store file`, `Failed move of compacted file`→`Could not place merged file`, `Compaction failed`→`Merge failed`, `Failed open of region=`→`Could not bring region online: region=`, `Starting/Completed [major] compaction of`→`Beginning/Finished [major] merge of`.
  - **Rebuild + re-reproduce** — 156 substitutions in 28 files; `repos/hbase4078-anon` builds and still reproduces: 4 files cut short in `.tmp`, **all four promoted into the live `cf/` directory**, `.tmp` empty, 1 `Merge failed`, 1 regionserver abort, 3 `DroppedSnapshotException`, 42 `Invalid HFile version`, **17 `Cannot read …`** reports across region opens. (`maven-compiler-plugin` 2.0.2 cannot parse javac 8's bootstrap-classpath warning and fails the first whole-tree compile, so `anonymize.sh` compiles twice — the same quirk the pre-fix tree shows at M2.)
  - **Artifacts** — `source/` = the 13 files of the completed causal chain; `logs/repro.log` (Log A) = 133 MB / 751 070 lines; `logs/symptom.log` (Log B, LLM-facing) = 3.19 GB = 11 945 370 production + 747 348 reproduction records, with `merge_logs.py --rename` applying the same vocabulary to the production stream so the reproduction lines are not the only differently-worded ones. The shared production log is never modified.
  - **Gate** (`private/verify_anon.py`, one streaming pass over `source/`, `logs/repro.log`, the whole 3.19 GB `logs/symptom.log` and `symptom.md`): **0 hits** for `HBASE-4078`, `\bStore\b`, `\bHStore\b`, `\binternalFlushCache\b`, `\bcompleteCompaction\b`, `\bloadStoreFiles\b`, `\bcompactStore\b`, `Failed open of`, `Renaming flushed file`, `presumption is that`, `corrupted at flush`, `Failed move of compacted file`, `Failed replacing compacted files`, `Compaction failed`, `Compaction Request failed`, `HBASE-646`, `Starting compaction of`, `Completed [major] compaction of`, `Replay of HLog required`, `Unable to rename`. The only surviving pattern is the **bare number** `4078` (27 in Log A, 202 in Log B) — every hit an ordinary counter (`responding to #4078`, `packet seqno=4078`, ZooKeeper `header:: 4078,1`) with no ticket reference; unavoidable in a multi-GB log and left as is.
- 2026-08-17T19:35:00Z agent-run-4ee9c5a7 — **M5 DONE (`success=true`)**.
  - `symptom.md` = one sentence of bare observable ("a store file of `usertable` cannot be read; every time the region is opened the region server reports it and carries on without it") + the prescribed merged-log pointer ("the log for this run is `logs/symptom.log`") + the WARN and its ten-frame stack **exactly as the log prints them**. Only the leading absolute timestamp is elided — it would act as an exact-position pointer into 3.19 GB. The pasted line is greppable: 5 occurrences of that `Cannot read …` line, 14 of `Invalid HFile version: 1652127846`.
  - **Deliberately absent** (anti-cheat, and the reason this bug needs care): no trigger, no mechanism, no at-fault class/method/branch, and **no mention of the compaction, the flush, the failed compaction or the regionserver abort** — naming those would hand over the shape of the answer, since the two root-cause sites *are* the flush promotion and the compaction promotion.
  - `private/ground_truth.md` carries both the real and the anonymized names plus a translation table: **site A** `Store.internalFlushCache` 521-533 (`FamilyStore.writeSnapshotFile`) and **site B** `Store.completeCompaction` 1221-1232 (`FamilyStore.installCompactionResult`); the wrong condition at both is that the move out of `.tmp` is guarded only by *"did the rename succeed"* / *"was anything written"*, never by *"can the file be opened"* — the open happens only after the move. `loadStoreFiles`' `catch (IOException) { continue; }` is recorded as the consequence site and explicitly **not** a pass.
  - Pre-registered bar (§8/§10): both sites **and** the missing-validation condition; per-run sub-scores `site_a`, `site_b`, `condition_stated`, `symptom_site_only` keep alternative bars auditable without a re-run.
- 2026-08-17T19:50:00Z agent-run-4ee9c5a7 — **M6 partially complete: 2 of 5 runs**. Runs 3-5 each returned `API Error: Request rejected (429) · Daily quota exceeded for model group "claude-opus-4-7". The quota resets at 2026-08-18T08:00:00-04:00.` — the shared gateway quota (HBase-3403 hit the same wall today). Their bodies were renamed to `diagnosis/run_N.QUOTA-FAILED.txt` so the harness's idempotency rule (skip a non-empty `run_N.md`) re-runs exactly those three; `run_1.md` and `run_2.md` are complete, stderr-clean, and must not be re-run.

  **Resume after 2026-08-18T12:00Z**, from the repo root:
  ```bash
  bash context/extract-yscope-anthropic-paper-validation-env.sh /tmp/ysa.env
  GW_IP=$(getent ahostsv4 llm-gateway.yscope.io | awk '{print $1}' | sort -u | head -1)
  docker run --rm --cap-add=NET_ADMIN --add-host "llm-gateway.yscope.io:$GW_IP" \
    --env-file /tmp/ysa.env -e IS_SANDBOX=1 \
    -v "$PWD/evaluations/HBase/HBase-4078:/bug" \
    --entrypoint bash clods-eval /bug/private/run_diagnosis.prodlog.sh /bug
  rm -f /tmp/ysa.env
  ```

  **Harness.** `private/run_diagnosis.prodlog.sh` is `context/run_diagnosis.sh` with exactly two deltas (diff = 3 hunks: its header, plus these): the §5/M6 prompt text, and §7's hardlink-not-copy staging of the 3.19 GB merged log. `context/` was **not** modified. One deployment-level addition was required on the `docker run`: `-e IS_SANDBOX=1`, because Claude Code 2.1.197 refuses `--permission-mode bypassPermissions` as root ("--dangerously-skip-permissions cannot be used with root/sudo privileges") and the container must be root for the iptables lock; it changes no isolation property (verified with a control run). Egress iptables-locked to `llm-gateway.yscope.io:443` only, model `claude-opus-4-7` effort `high`, `--bare --no-session-persistence --exclude-dynamic-system-prompt-sections`, Bash/Write/Edit/WebFetch/WebSearch/Task/NotebookEdit denied, staging holds only `source/` + `logs/symptom.log` + `symptom.md`, single turn, no follow-ups.

  **Preliminary (ungraded) reading of runs 1-2.** Both traced the *symptom* path exhaustively and correctly — `FamilyStore.openStoreFiles`' `catch (IOException) { WARN; continue; }` at 268-273, `StoreFile.createReader` → `HFile.pickReaderVersion` → `FixedFileTrailer.readFromStream:306` → `HFile.checkFormatVersion`'s `version < 1 || version > 2` at `HFile.java:473` — and both concluded the root cause is "the HFile trailer is corrupt" plus the swallow-and-continue policy. **Neither named either site the fix changed** (0 mentions of `writeSnapshotFile` = `internalFlushCache`, or `installCompactionResult` = `completeCompaction`); neither asked how an unreadable file came to be in the live column-family directory in the first place. Run 2 goes further and calls the skip "not a second bug … the *intentional* policy" — the opposite of the ticket's judgment.
- 2026-08-17T20:42:00Z agent-run-4ee9c5a7 — M6 retry attempted early (operator asked whether the quota had freed up). **Still blocked**, and worth recording precisely: a *trivial* probe through the gateway (`claude -p "Reply with exactly: OK"`, same model `claude-opus-4-7`, same effort, same credentials) **succeeds**, while the three real diagnosis runs are rejected with the identical `429 · Daily quota exceeded … resets at 2026-08-18T08:00:00-04:00`. The quota is enforced on request volume/size rather than request count, and a diagnosis request (staged source tree plus a 3.19 GB log to grep, effort `high`) is orders of magnitude larger than the probe. **A cheap probe is therefore not a valid readiness test** — only re-running the harness after the stated reset is. Runs 3-5 re-parked as `run_N.QUOTA-FAILED.txt`; runs 1-2 were correctly skipped by the harness's idempotency rule.
