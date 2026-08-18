# Reproduction — HDFS-14135

## Symptom being reproduced

A WebHDFS client run drives a request at a NameNode HTTP endpoint whose listen queue is
supposed to be saturated, so the request is expected to fail while *connecting*. Instead the
connection is established, and the request fails ~200 ms later on the **read** deadline. The
run therefore reports a failed expectation:

```
java.lang.AssertionError:  Expected to find 'localhost:35917: connect timed out' but got
unexpected exception: java.net.SocketTimeoutException: localhost:35917: Read timed out
```

It is **intermittent**: in the captured run one of three identical repetitions failed (1 of
its 16 checks), the other two passed.

## How to run it

```bash
cd /mnt/SSD-4T/ycx/CLODS
docker run --rm --cap-add=NET_ADMIN \
    -v "$PWD:/work" -v "$PWD/repos/.m2-HDFS-HDFS-14135:/root/.m2" \
    --entrypoint bash clods-eval:HDFS-HDFS-14135 \
    -lc 'bash /work/evaluations/HDFS/HDFS-14135/reproduce.sh'
# then merge the reproduction into the shared production log (M3 step 8):
python3 evaluations/HDFS/HDFS-14135/private/merge_logs.py \
    --production production-logs/HDFS/production.log \
    --repro     evaluations/HDFS/HDFS-14135/private/symptom.orig.log \
    --out       evaluations/HDFS/HDFS-14135/private/merged.orig.log \
    --interleave position
```

`SRC_TREE=` overrides the source tree, `OUT_LOG=` the destination log and `SUITE=` the
class exercised, so M4's `private/anonymize.sh` re-runs the same script against the renamed
rebuild to produce `logs/repro.log` and, after the same merge, `logs/symptom.log`.
Exit code 0 = reproduced.

`--cap-add=NET_ADMIN` is required: the script shapes the loopback device (below).

## Scenario

1. **Build**: the pre-fix tree (`b7fba78fb63`, Hadoop 3.3.0-SNAPSHOT) built from source,
   `mvn -pl hadoop-hdfs-project/hadoop-hdfs -am package -DskipTests` (M2).
2. **Loaded-host network timing**: `tc qdisc replace dev lo root netem delay 2ms`. This adds
   2 ms of latency to loopback — the timing of a busy CI/production host. **No line of the
   system under test is changed**; the delay only makes the pre-existing race lose often
   enough to observe. See "Deviation" below.
3. **Ordinary WebHDFS traffic** (`private/repro/Workload.java`) against a **real
   MiniDFSCluster** (NameNode + 3 DataNodes), root logger at DEBUG: `mkdirs`, `create` +
   256 KB writes, full `open`/read-back, `getFileChecksum`, `rename`, `listStatus` and
   `delete`, over the real WebHDFS REST client — 3 files before and 2 files after the
   failing activity.
4. **The failing activity**: the real WebHDFS socket-deadline suite
   (`org.apache.hadoop.hdfs.web.TestWebHdfsTimeouts`, 16 parameterized checks) run **three
   times**, the way CI re-runs a job, each with the root logger at DEBUG.
5. The five session logs are concatenated into `private/symptom.orig.log` using the shared
   production log's own `host__path` collection headers
   (`hadoop-client7__opt_hadoop_logs__hadoop.log`, `…log.1`, …). No header names a run
   "failing".

## What is triggered

Each connect-deadline check first saturates the listen queue of the bogus NameNode HTTP
server (`new ServerSocket(0, 1)`) by opening 129 **non-blocking** `SocketChannel`s and
calling `connect()` on each. Because the channels are non-blocking, `connect()` only
*initiates* each handshake; the helper returns as soon as the last call has been issued,
without ever confirming that the kernel's accept queue is actually full. With 2 ms of
loopback latency the handshakes are still in flight at that moment, so the queue still has
room: the client's next connection is **accepted**, and the request then fails on the read
deadline instead of the connect deadline — which is what the check reports.

The DEBUG trace of the failing repetition shows exactly that, with no connect failure
preceding it:

```
DEBUG org.apache.hadoop.hdfs.web.URLConnectionFactory: open URL connection
DEBUG org.apache.hadoop.security.UserGroupInformation: PrivilegedActionException as:root
      (auth:SIMPLE) cause:java.net.SocketTimeoutException: localhost:35917: Read timed out
```

followed by the run's own failure report (`java.lang.AssertionError: Expected to find
'localhost:35917: connect timed out' …`) whose stack walks
`WebHdfsFileSystem.validateResponse → AbstractRunner.connect → runWithRetry → run →
getDelegationToken` back into the suite. In the **anonymized** M4 build the class name and
the failure-path literals are the renamed ones (see `private/anonymization_map.json`).

## How it is detected (silent — nothing is injected into the log)

`reproduce.sh` asserts, from the collected log and the traffic driver's result file:

| assertion | observed |
|---|---|
| at least one repetition fails | suite run 1 exit=1, `Tests run: 16, Failures: 1`; runs 2 and 3 `OK (16 tests)` |
| a read deadline is reported where a connect deadline was expected | `Expected to find 'localhost:35917: connect timed out' but got unexpected exception: java.net.SocketTimeoutException: localhost:35917: Read timed out` |
| ordinary WebHDFS traffic completed | `written=3 read=3 checksums=3 renamed=3 listed=4 deleted=1 error=` |

`Workload.java` **never writes to stdout or stderr** — its observations go to
`private/result_a.txt` / `private/result_b.txt`, which are not part of either log. The
assertion verdicts are printed by `reproduce.sh` to its own stdout only. **No print or log
statement was added to Hadoop anywhere**; every line in the logs is the system's own DEBUG
output or the test runner's own failure report.

## The two logs (M3 step 8)

| | file | what it is |
|---|---|---|
| **Log A** | `private/symptom.orig.log` (pre-anon) → `logs/repro.log` (anon) | the standalone reproduction: 2 WebHDFS/MiniDFSCluster sessions + 3 suite repetitions, **17 990 lines / 3.5 MB / 15 244 records**. Kept for reference; **never given to the LLM**. |
| **Log B** | `private/merged.orig.log` (pre-anon) → `logs/symptom.log` (anon) | Log A merged into the shared production log — **49 711 986 lines / 7.4 GB** = 26 323 996 production + 15 244 reproduction records. This is what the LLM gets. |

The shared production log is `production-logs/HDFS/production.log` (7.0 GB, 26 323 996
records, HDFS DEBUG under YCSB + chaos monkey, span `2026-08-14 19:23:20,772 ..
19:30:45,728`, 37 concatenated per-host sections: `hadoop-master` + `hadoop-dn1..dn15` and
their rotations). It is **read-only and never modified** — the merge only reads it.

Findability check on the merged log: the observable is one `grep` away
(`AssertionError` → 1 hit at line 26 861 632, i.e. 54 % into the file), while its
reproduction neighbours are ~1 727 production records apart, so the failure sits inside
unrelated production traffic rather than in a clean block.

### Merge deviation, stated plainly

`private/merge_logs.py` is `Zookeeper-1851`'s tool copied with its body unmodified (via
`HBase-3403`), invoked with `--interleave position` for the same reason: the shared HDFS
production log is **37 concatenated per-host sections**, each restarting the clock over the
same ~7.5-minute window, not one globally sorted timeline. A literal timestamp merge would
therefore collapse the whole reproduction into the first section as one contiguous foreign
block. `position` keeps the specified **retiming** rule unchanged (linear warp of the
reproduction span onto the production span, preserving relative ordering and gaps) and
changes only the interleaving key to proportional record position. Measured spread: the
reproduction's five session boundaries land at merged lines 1 / 26.2 M / 26.9 M / 27.5 M /
28.2 M, i.e. one reproduction record roughly every 1 727 production records across the file.

Consequence worth knowing: the reproduction's real 33-second span is warped onto the
production log's 7.5-minute span (≈13×), so a 200 ms deadline in the reproduction appears as
a ≈2.7 s gap between neighbouring reproduction records. The *content* of every line —
including the deadline values the code prints — is untouched.

## Test-only infrastructure (for auditing)

- `private/repro/Workload.java` — a traffic driver that only calls public Hadoop APIs
  (`MiniDFSCluster.Builder`, `WebHdfsTestUtil.getWebHdfsFileSystem`, `FileSystem`
  create/open/rename/listStatus/getFileChecksum/delete). It reports what it observed to a
  result file so nothing it says can leak into either log. It adds no instrumentation to
  Hadoop and reads no internal state.
- `private/repro/log4j-repro.properties` — root logger at DEBUG with the shared production
  log's own layout (`%d{ISO8601} %-5p %c: %m%n`), so the reproduction and the production
  noise read as one collection.
- `private/repro/loop.sh` — the calibration harness used to measure how often the suite
  fails at a given loopback latency (not part of the reproduction itself).
- `private/merge_logs.py` — the M3 step-8 merge (read-only on the shared production log).
- No production source was changed at M3. The only dependency fix is toolchain-level
  (protobuf 2.5.0 compiler, `private/deps-fix.patch` + `private/Dockerfile`); no `pom.xml`
  was edited.

## Caveats

- **The 2 ms loopback delay is the one environmental knob.** Without it this defect is a
  genuinely rare race: 10 consecutive suite runs on an idle single-CPU container all passed.
  Measured failure profile (`private/repro/loop.sh`): 2 ms → 1–2 of 16 checks fail per run
  (the profile used here, matching the ticket's "fails intermittently"); 5 ms and 10 ms →
  6–7 of 16 fail per run; 50 ms → all 8 connect-deadline checks fail every run. The delay
  changes *when* the handshakes complete, not *what* the code does; the wrongly-ordered
  work it exposes is entirely in the pre-fix source.
- Client, server and cluster all run in one container on loopback, not on separate
  production hosts. This affects timing only.
- The failing activity is a test-suite run rather than a long-lived daemon, because this
  defect lives on the client/verification path that a full cluster never executes; the
  ordinary WebHDFS traffic in steps 3 and 5 is real cluster activity (NameNode + 3
  DataNodes) captured in the same log.
- The merged log mixes two Hadoop builds: the production sections come from a different
  version than `source/`, so production lines carry different logger/line detail than the
  reproduction lines. That is inherent to merging one shared production log into every bug.
