# HBase-4078 — how the failure was reproduced

**System under test:** HBase `0.93-SNAPSHOT` built from the **pre-fix** commit
`9814ffbaf0eca469bbded025a1dca81271c6d4e6` (the parent of the fix commit
`df9b82c082`), on **HDFS 1.0.4**. Everything below runs inside the per-bug container
`clods-eval:HBase-HBase-4078` (`clods-eval` + `openjdk-8-jdk`).

```bash
docker run --rm -v /mnt/SSD-4T/ycx/CLODS:/work -v hbase4078-m2:/root/.m2 \
  --entrypoint bash clods-eval:HBase-HBase-4078 \
  /work/evaluations/HBase/HBase-4078/reproduce.sh
```

---

## 1. The deployment (a real cluster, not a minicluster)

`reproduce.sh` brings up seven JVMs and drives them with an ordinary HBase client:

| Process | What it is |
|---|---|
| NameNode + 2 DataNodes | real HDFS 1.0.4 (`dfs.replication=2`, `dfs.support.append=true`), serving `hbase.rootdir=hdfs://localhost:8020/hbase` |
| `HQuorumPeer` | HBase's ZooKeeper |
| `HMaster` | real master |
| `HRegionServer` × 2 | ports 60020 / 60021, own conf dirs, own log files |
| `clods.Client` | ordinary client: `HTable` puts/gets/scans/deletes and `HBaseAdmin` flush/compact/move |

Every HBase JVM runs with the **root logger at DEBUG** and the shared production log's own
layout (`%d{ISO8601} %-5p [%t] %c: %m%n`). The table is `usertable`, family `cf`, with
YCSB-shaped row keys (`user%09d`), so the reproduction and the shared HBase production log
read alike.

## 2. Scenario

**Phase A — ordinary traffic on a healthy filesystem.** 36 000 rows are written in four
batches (3 writer threads, 5 columns × 180 B per row), each batch followed by an operator
`flush`, then a 4-thread mixed read/update/scan/delete workload for 45 s (36 988 ops, **0
failures**). The store ends up with four real store files of 9 956 120 B each and a full
scan returns exactly **36 000** rows.

**Phase B — the filesystem incident.** A marker file opens a bounded window during which the
filesystem is flaky (§4). Traffic keeps running throughout. Inside the window:

1. an operator **major compaction** is requested — the regionserver merges the four files
   into `.tmp/65629880766638568` (39 822 970 B written) and the filesystem keeps only
   21 902 633 B of it;
2. 6 000 more rows are loaded and a **memstore flush** happens — its output is cut short the
   same way.

**Phase C — aftermath.** The window closes; the regionserver that aborted is restarted, and
the region is **moved** between the two servers twice (ordinary operator actions), with mixed
traffic between the moves.

## 3. What the pre-fix code does with the short files (the failure)

Every one of the cut-short files was **moved out of `.tmp` into the region's live
column-family directory** and only *then* opened:

```
--- files the filesystem cut short during the incident window:
.../f590c6f78011475a41ca980a00badd33/.tmp/65629880766638568   39822970 -> 21902633   (compaction output)
.../f590c6f78011475a41ca980a00badd33/.tmp/7423108526757200449  8427637 ->  4635200   (flush output)
.../f590c6f78011475a41ca980a00badd33/.tmp/7732412745290965411  8361349 ->  4598741   (flush during region open)
.../f590c6f78011475a41ca980a00badd33/.tmp/2906742884328292086  8361349 ->  4598741   (flush during region open)

--- what is in the table's column-family directory afterwards:
.../cf/2825368576628738235 44952978     <- healthy (a later successful compaction)
.../cf/3355567546535143948 21902633     <- the short compaction output, promoted
.../cf/3784820059589198517  4598741     <- short flush output, promoted
.../cf/3901243280552791245  4598741     <- short flush output, promoted
.../cf/8438656049107224152  4635200     <- short flush output, promoted

assertion 1 (every cut-short file left .tmp and is now in the live store directory): ok
assertion 2 (nothing was left behind in .tmp):                                       ok
```

Consequences, all in the cluster's own log (`private/symptom.orig.log`):

* the compaction dies **after** its output is already in the store directory —
  `ERROR ... compactions.CompactionRequest: Compaction failed regionName=usertable,…`;
* the flush dies the same way, which costs the regionserver its life —
  `FATAL [regionserver60021.cacheFlusher] ... HRegionServer: ABORTING region server
  51453305dbda,60021,…: Replay of HLog required. Forcing server shutdown`;
* from then on **every** region open trips over the promoted files — 17 `Failed open of
  hdfs://…/cf/<file>` warnings from `regionserver.Store` across the two regionserver logs,
  each carrying
  `java.io.IOException: java.lang.IllegalArgumentException: Invalid HFile version:
  1886087525 (expected to be between 1 and 2)` at
  `FixedFileTrailer.readFromStream:306 ← HFile.pickReaderVersion:330 ← HFile.createReader:346
  ← StoreFile$Reader.<init>:983 ← StoreFile.open:444`;
* two region opens fail outright — `ERROR ... handler.OpenRegionHandler: Failed open of
  region=usertable,…` with `DroppedSnapshotException` raised from
  `HRegion.replayRecoveredEditsIfAny:2217`;
* the files are **never** cleaned up and are silently skipped on each subsequent open, which
  is the ticket's "this keeps happening as the region moves around".

The cluster keeps serving throughout (0 client failures in every mixed phase). A final full
scan returns **40 990** rows where 42 000 distinct keys were written; the workload's
field-level deletes cannot account for more than a handful of whole rows, but part of that
shortfall may also come from WAL-tail loss during log splitting on Hadoop 1.0.4 rather than
from this bug, so **the row shortfall is reported as an observation only** — the causally
attributable observable is the promotion of unreadable files into the live store directory
and the endless "cannot open this file" reports that follow.

## 4. How the filesystem is made flaky (test-only infrastructure — declared)

`private/repro/DistributedFileSystemImpl.java` is a **subclass of
`org.apache.hadoop.hdfs.DistributedFileSystem`** installed via `fs.hdfs.impl`. While a marker
file exists on local disk, a file created under a region's `.tmp` directory loses the tail of
its data at `close()` — every `write()` and `close()` still returns success. That is the
fault the ticket names: *"improperly moving partially-written files from TMP into the region
directory when a FS error occurs"*.

* **No HBase source is modified**, and **no log or print statement is added anywhere** — HBase
  observes the state of the file exactly as it would with a genuinely flaky HDFS.
* It is a real `DistributedFileSystem`, so every `instanceof` check, lease-recovery path and
  URI in HBase stays untouched.
* The incident is **bounded on purpose**: only paths under `/usertable/` and at most two files
  per regionserver JVM (`hdfs.incident.scope`, `hdfs.incident.max`). Without the bound, a
  region-open retry re-flushes and is cut short again, and one incident becomes an unbounded
  open/flush loop that buries the failure under its own retries (observed: an unbounded run
  put `.META.` into exactly such a loop).
* Its only other output is `incident.record`, a plain harness file listing which paths were
  cut short — it is **not** a log and is not part of either captured log.

`private/repro/Client.java` is an ordinary HBase client (workload + `HBaseAdmin`
flush/compact/move + HDFS listings for the assertions). Its output goes to `reproduce.sh`'s
stdout, **not** into the captured logs.

## 5. Detection (silent — no injected markers)

All assertions read the cluster's own reporting surfaces and print only to `reproduce.sh`
stdout: HDFS directory listings (`Client storefiles`), the servers' own log files, and the
client's row counts. Nothing is written into the captured log to signal that the bug fired.

## 6. The two logs

| Log | Path | Size |
|---|---|---|
| **A** — standalone reproduction | `private/symptom.orig.log` | 139.7 MB, 790 805 lines (785 597 DEBUG, 1 307 INFO, 46 WARN, 7 ERROR, 2 FATAL) |
| **B** — merged with production | `private/merged.orig.log` | 3.19 GB, 11 945 370 production + 786 959 reproduction records |

Log A bundles the four daemon logs with `===== <name>__var_log_hbase__<file> =====` headers,
the same shape as the shared production log. Log B is produced by `private/merge_logs.py`
(Zookeeper-1851's tool, copied verbatim) per METHODOLOGY §5/M3 step 8: only each reproduction
record's leading timestamp is rewritten — linearly warped from the reproduction span
(`2026-08-17 18:43:33,544 … 18:48:40,160`) onto the full production span
(`2026-08-14 19:06:45,717 … 19:31:38,751`) — and the records are interleaved into
`production-logs/HBase/production.log`, which is never modified. `--interleave position` is
used because the shared HBase production log is a bundle of per-host sections rather than one
globally sorted timeline (a pure timestamp merge would collapse the whole reproduction into
the first section).

## 7. Caveats

* Single host: HDFS and HBase daemons are separate JVMs on one machine, not separate
  machines; replication is 2 across two DataNodes on the same disk.
* Hadoop 1.0.4 is used instead of the tree's original `0.20-append-r1057313`, which was never
  published anywhere still reachable (see `private/deps-fix.patch`).
* The corruption is injected at the filesystem layer rather than by a physically failing disk;
  it is deterministic and bounded so the experiment is repeatable.
* The row-count shortfall in §3 is not claimed as a consequence of this bug (see the note
  there).
