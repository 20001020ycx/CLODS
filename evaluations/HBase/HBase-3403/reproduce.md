# HBase-3403 — how the failure is reproduced

## Scenario

A single-region table is split on a live two-node mini cluster; the region server that
carried the split is then killed while one daughter is missing from `.META.`; the master is
given three minutes to bring the cluster back to a consistent state; finally HBase's own
consistency checker is asked to report on the cluster.

On the **pre-fix** tree (`dddee0d50ff77c93a2b39f408bf11f60e397ebf4`) the daughter is never
recovered: its directory sits on HDFS, no `.META.` row points at it, and no region server
serves it.

## Commands

Everything runs inside the per-bug container (JDK 8; see `PROGRESS.md` M2 for the image and
the dependency fixes) with the CLODS repo mounted at `/work`:

```bash
# M3 — reproduce on the pre-fix tree, log -> private/symptom.orig.log
docker run --rm -v "$PWD:/work" --entrypoint bash \
  clods-eval:HBase-HBase-3403 /work/evaluations/HBase/HBase-3403/reproduce.sh

# M3 step 8 — merge that log into the shared production log (host, read-only on production)
python3 evaluations/HBase/HBase-3403/private/merge_logs.py \
  --production production-logs/HBase/production.log \
  --repro      evaluations/HBase/HBase-3403/private/symptom.orig.log \
  --out        evaluations/HBase/HBase-3403/private/merged.orig.log \
  --interleave position
```

`reproduce.sh` builds (`mvn -B -s .../settings.xml -DskipTests test-compile`), runs the
single test `org.apache.hadoop.hbase.util.TestSplitCrashRecovery`, and copies surefire's
captured console output to the output log. At M4 the same script is re-run against the
anonymized tree with `SRC=` and `OUT_LOG=` overridden.

## How the failure is triggered

The test drives the real code path; nothing is stubbed or mocked:

1. `TESTING_UTIL.createTable("usertable", …)` — one region, then moved (via `admin.move`)
   so it is **not** on the server carrying `.META.`; the balancer is switched off.
2. `TESTING_UTIL.loadTable(t, …)` writes rows so the region is splittable.
3. `admin.split(region)` — a genuine `SplitTransaction` on the region server. This is what
   drives `MetaEditor.offlineParentInMeta`, visible in the log as
   `MetaEditor: Offlined parent region usertable,,….62ab8f3c…. in META`.
4. The daughter's `.META.` row is deleted (`HTable.delete` on the region's row). This is the
   **crash-window simulation**: in the field the region server dies after the split has been
   committed in `.META.` but before both daughters have been written up into it, so one
   daughter simply has no `.META.` row. Deleting the row reproduces that end state exactly
   without having to win a race against the split's own commit. The upstream fix's test
   (`TestSplitTransactionOnCluster.testShutdownSimpleFixup`) simulates it the same way.
5. `cluster.abortRegionServer(index)` kills that server, which is what the reporter did in
   the JIRA (`kill -9` on all servers). The master then runs its shutdown recovery.
6. The test polls `.META.` for the missing daughter for up to 180 s.

## How the failure is detected

Two independent surfaces, neither of them an injected log line:

- **Assertion (test runner, not the log).** The test asserts the daughter has a `.META.`
  row within 180 s. On the pre-fix tree it does not:

  ```
  java.lang.AssertionError: region usertable,,1786932488231.6751938fd298a88f2f50496c0afca9aa.
    is still absent from .META. 180s after the server that carried it was lost
  ```

  The assertion message goes to surefire's `<class>.txt` report, **not** into the captured
  console output that becomes the symptom log.

- **The shipped consistency checker (system output).** After the recovery window the test
  calls `HBaseFsck` (`hbck`) — the tool an operator would run — with `setTimeLag(0)` so it
  does not skip freshly written regions. Its own report goes to stdout and therefore into
  the log:

  ```
  ERROR: Region hdfs://localhost:46335/user/root/usertable/6751938fd298a88f2f50496c0afca9aa on HDFS, but not listed in META or deployed on any region server.
  ERROR: Found inconsistency in table usertable
  …
  Table usertable is inconsistent.
  2 inconsistencies detected.
  Status: INCONSISTENT
  ```

  This is the same observable the JIRA reporter posted. (At M4 the literals `HBaseFsck`
  emits are rewritten, so the anonymized log carries information-equivalent but different
  wording.)

The causal trace is present in the log as ordinary system output, e.g. the master reporting
that it found only **one** region for the dead server:

```
ServerShutdownHandler: Reassigning 1 region(s) that 2a632be62ab9,35951,… was carrying (skipping 0 regions(s) that are already in transition)
ServerShutdownHandler: Finished processing of shutdown of 2a632be62ab9,35951,…
```

No `Offlined and split region … checking daughter presence` and no `Fixup; missing daughter`
line ever appears — the daughter-fixup code is never reached.

## Captured logs

| Log | Path | Size | What it is |
|---|---|---|---|
| A (standalone) | `private/symptom.orig.log` | 7 415 lines | the reproduction's own console output, pre-anonymization |
| B (merged) | `private/merged.orig.log` | 12 002 242 lines / 3.06 GB | Log A retimed and interleaved into `production-logs/HBase/production.log` |

Both are the system's own log4j/`hbck` output at DEBUG. **No line is injected by the test**:
the test class logs nothing of its own, and no probe/`println` was added to production code.

A shared HBase production log exists (`production-logs/HBase/production.log`, 3.06 GB,
11 945 370 records, HBase 1.2.7 under YCSB + chaos monkey), so the M3 merge applies — the
legacy standalone-log fallback is **not** used.

### Merge details

`private/merge_logs.py` is `Zookeeper-1851`'s tool copied with its body unmodified, so every
bug merges the same way. Production span `2026-08-14 19:06:45,717 .. 19:31:38,751`
(11 945 370 records); reproduction span `2026-08-17 02:07:43,144 .. 02:11:14,636`
(7 362 records). Each reproduction record's timestamp is linearly warped onto the full
production span and reformatted in the production log's format; every other character of
every line is kept verbatim, and no production line is touched (the shared production log is
read-only).

**Interleaving deviation, same as the ZooKeeper bugs:** `--interleave position`, not the
spec's literal timestamp merge. The HBase production log is a bundle of **20 concatenated
per-host sections** (`hbase-master`, `hbase-rs1`…`hbase-rs10` plus rotations), each
restarting the clock over the same ~25-minute window, so it is not one globally sorted
timeline; a pure timestamp merge would collapse the whole reproduction into the first
section as one contiguous foreign block, which is exactly what the methodology forbids. The
retiming rule is unchanged; only the insertion key differs, so the 7 362 reproduction
records are spread evenly across all 20 sections (one roughly every 1 620 production
records).

## Test-only infrastructure (nothing else deviates from the production path)

- `src/test/java/org/apache/hadoop/hbase/util/TestSplitCrashRecovery.java` — the test itself
  (`private/repro-test.patch`). It lives in the `…hbase.util` package solely because
  `HBaseFsck.setTimeLag`/`doWork` are package-private.
- `hbase.catalogjanitor.interval` is set to `Integer.MAX_VALUE` for the mini cluster so the
  catalog janitor cannot delete the offlined parent's `.META.` row mid-scenario. This is a
  **configuration** value, not a code change. (The upstream fix added a
  `setCatalogJanitorEnabled` hook for the same purpose; that hook does not exist pre-fix.)
- `src/test/resources/log4j.properties` — root logger raised to `DEBUG`,
  `org.apache.hadoop` from `WARN` to `INFO`, `org.apache.zookeeper` from `ERROR` to `INFO`,
  and the console pattern changed to `%d %-5p [%t] %c: %m%n` so the reproduction log has the
  same layout as the shared production log it is merged into. Levels and layout only; no
  statement was added, removed, or reworded here.
- Build-only dependency fixes are separate and documented in `PROGRESS.md` M2 /
  `private/deps-fix.patch` (hadoop `0.20-append-r1056497` → `0.20.2`, thrift dropped, one
  `(K[])` cast for javac 8).

## Caveats

- This is a two-region-server **mini cluster** in one JVM with a `MiniDFSCluster`, not a
  multi-machine production cluster; region servers are aborted in-process rather than
  `kill -9`'d.
- The tree is built against Hadoop `0.20.2` instead of the 2011 `0.20-append` snapshot
  (that artifact no longer exists anywhere). The failure is entirely within HBase's
  `.META.` bookkeeping and does not depend on HDFS append/sync.
- The lost daughter's `.META.` row is deleted rather than being lost to a real crash race
  (see step 4 above); the resulting cluster state is identical, and the master's shutdown
  recovery — the code under test — runs completely untouched.
