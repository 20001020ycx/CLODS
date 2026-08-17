# HBase-3627 — how the failure is reproduced

Everything below runs the **real system**: a three-regionserver HBase cluster built from the
**pre-fix source tree** (branch-0.90 @ `86e9f5f8c9`, `0.90.2-SNAPSHOT`), driven by an ordinary
HBase client. **No HBase source is patched and no log or print statement is added anywhere** —
every line in the captured log is the servers' own output. Detection is silent: the assertions
at the end of `reproduce.sh` read the servers' logs and the clients' result files and print only
to the script's stdout.

## Command

```bash
# per-bug container, CPU-limited so that region opens are slow relative to the master's
# regions-in-transition timeout (an ordinary, overloaded two-core node)
docker run -d --name hbase3627 --cpus=2 -v "$PWD:/work" \
    -v "$PWD/repos/.m2-HBase-3627:/root/.m2" --entrypoint bash \
    clods-eval:HBase-HBase-3627 -lc 'sleep infinity'

docker exec hbase3627 bash /work/evaluations/HBase/HBase-3627/reproduce.sh
#   reproduce.sh [HBASE_SRC] [RUNDIR] [OUT_LOG]
#   defaults: /work/repos/HBase-HBase-3627, /work/repos/hbase-run-3627,
#             /work/evaluations/HBase/HBase-3627/private/symptom.orig.log
```

`reproduce.sh` builds the tree if needed (`mvn -DskipTests -Dmaven.javadoc.skip=true package`,
the M2 command), writes the per-daemon conf (`private/repro/mkconf.sh`), starts and stops the
daemons (`private/repro/cluster.sh`, which just calls the shipped `bin/hbase-daemon.sh`), and
drives traffic with `private/repro/CreateTable.java` + `private/repro/Workload.java` (public
client API only: `Put`/`Get`/`Scan`/`Delete`).

## Scenario

| phase | what happens |
|---|---|
| **A** | 1 master + 3 regionservers + 1 ZooKeeper come up on one host, `hbase.rootdir` on the local filesystem. A `usertable` is created **pre-split into 300 regions**; 12 client threads write **3 000 000 rows of 1 KB**; then a mixed read/write/scan/delete workload runs against it. Compaction is switched off and the memstore flush size is 256 KB, so every region ends up with tens of store files — an ordinary "compactions have fallen behind" cluster whose regions are slow to open. |
| **B** | **The incident: the operator restarts the cluster** (all daemons stopped, then started again). The master bulk-assigns all 300 regions across the three regionservers far faster than they can open them. |
| **C** | Client traffic runs across the restart and after it (6 threads × 20 000 mixed ops), plus a post-incident probe. |

### How the failure is triggered

The master hands a region to a regionserver and puts it in `PENDING_OPEN`; the regionserver
queues an `OpenRegionHandler` for it. Because opens are slower than assignment, the handler is
still queued when the master's regions-in-transition monitor decides the region has been
`PENDING_OPEN` for too long, and **reassigns the region to a different regionserver**. That
second server opens it, transitions the unassigned znode to `OPENED`, and the master **deletes
the znode**. The first server's handler then finally runs and tries to claim a znode that is no
longer there: `ZKUtil.getDataNoWatch` returns `null`, `ZKAssign.transitionNode` passes that
`null` straight into `RegionTransitionData.fromBytes` → `Writables.getWritable`, and the region
open dies on a `NullPointerException` that `EventHandler.run` catches and logs.

Three ordinary settings compress, on a small two-core node, the condition the ticket describes
on a large production cluster ("when a region takes too long to open"). They are ordinary
operator knobs; **none of them changes any code path** — they only change how quickly the
master gives up on a slow open:

| setting | value (default) | why |
|---|---|---|
| `hbase.master.assignment.timeoutmonitor.timeout` | 2000 (30000) | how long a region may sit in transition before the master reassigns it |
| `hbase.master.assignment.timeoutmonitor.period` | 500 (10000) | how often that check runs |
| `hbase.bulk.assignment.waiton.empty.rit` | 2000 (600000) | how long a cluster-wide assignment waits for regions-in-transition to drain before "the RIT monitor should do fixup" (the code's own comment). On a real cluster with enough regions the default is exceeded naturally; here it is shortened so the monitor takes over while opens are still queued. |
| `hbase.regionserver.executor.openregion.threads` | 1 (3) | a single open-region worker per server, so the open queue is deep |

### How the failure is detected

Silently, by reading the servers' own logs after the fact (`reproduce.sh` prints the counts to
its stdout; nothing is written into any HBase log):

```
regions-in-transition timeouts logged by the master : 7181
M_RS_OPEN_REGION handler failures on regionservers   : 4740
  ...of which the stack passes through ZKAssign      : 14223   (3 frames per failure)
znode reads that found no node                       : 4741
```

The failure as the regionserver logs it — identical to the trace attached to the JIRA report:

```
2026-08-17 03:35:47,214 DEBUG [RS_OPEN_REGION-hbase3627,60021,...-0] handler.OpenRegionHandler: Processing open of usertable,user0000826666,...
2026-08-17 03:35:47,214 DEBUG [RS_OPEN_REGION-hbase3627,60021,...-0] zookeeper.ZKAssign: regionserver:60021-0x... Attempting to transition node 82f9edff... from M_ZK_REGION_OFFLINE to RS_ZK_REGION_OPENING
2026-08-17 03:35:47,214 DEBUG [RS_OPEN_REGION-hbase3627,60021,...-0] zookeeper.ZKUtil: regionserver:60021-0x... Unable to get data of znode /hbase/unassigned/82f9edff... because node does not exist (not necessarily an error)
2026-08-17 03:35:47,215 ERROR [RS_OPEN_REGION-hbase3627,60021,...-0] executor.EventHandler: Caught throwable while processing event M_RS_OPEN_REGION
java.lang.NullPointerException
        at org.apache.hadoop.hbase.util.Writables.getWritable(Writables.java:75)
        at org.apache.hadoop.hbase.executor.RegionTransitionData.fromBytes(RegionTransitionData.java:198)
        at org.apache.hadoop.hbase.zookeeper.ZKAssign.transitionNode(ZKAssign.java:673)
        at org.apache.hadoop.hbase.zookeeper.ZKAssign.transitionNodeOpening(ZKAssign.java:552)
        at org.apache.hadoop.hbase.zookeeper.ZKAssign.transitionNodeOpening(ZKAssign.java:545)
        at org.apache.hadoop.hbase.regionserver.handler.OpenRegionHandler.transitionZookeeperOfflineToOpening(OpenRegionHandler.java:297)
        at org.apache.hadoop.hbase.regionserver.handler.OpenRegionHandler.process(OpenRegionHandler.java:90)
        at org.apache.hadoop.hbase.executor.EventHandler.run(EventHandler.java:151)
        at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1149)
        at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:624)
        at java.lang.Thread.run(Thread.java:750)
```

Client-visible effect during the incident: the clients keep working (HBase retries a region that
is not being served), so `during_incident.txt` reports 0 hard failures; the visible damage is the
failed region bring-ups and the resulting assignment churn in the servers' logs.

## The two captured logs

| log | what it is | size |
|---|---|---|
| `private/symptom.orig.log` *(Log A, gitignored)* | the standalone reproduction: the five daemon logs (master, rs1-3, ZooKeeper) plus the five client session logs, each prefixed by a `===== file: … =====` header. Everything at DEBUG. | 1 662 415 lines / 244 MB (1 490 478 DEBUG, 75 392 INFO, 2 834 WARN, 4 758 ERROR) |
| `private/merged.orig.log` *(Log B, gitignored)* | Log A merged into the shared read-only `production-logs/HBase/production.log` (HBase 1.2.7 under YCSB + chaos monkey, 11 945 370 records, span `2026-08-14 19:06:45,717 .. 19:31:38,751`) by `private/merge_logs.py` | 13 657 242 lines / 3.3 GB = 11 945 370 production + 1 573 462 reproduction records |

Merge rule (METHODOLOGY §5/M3 step 8): **retime, do not rewrite.** Only each reproduction
record's leading timestamp is changed — linearly warped from the reproduction span onto the full
production span; every other character of every line is verbatim, and the production log itself is
never modified. `--interleave position` is used (as for the ZooKeeper bugs) because
`production-logs/HBase/production.log` is a **bundle of 19 concatenated per-host sections**
(`hbase-master`, `hbase-rs1..rs10` and their rotations), each restarting the clock over the same
25-minute window; a literal timestamp merge would collapse the whole reproduction into the first
section instead of spreading it across the timeline. `merge_logs.py` is Zookeeper-1900's tool
copied verbatim, so every bug merges the same way.

## Test-only infrastructure

**None in the system under test.** The only non-HBase code is the client driver
(`private/repro/Workload.java`, `CreateTable.java`), which uses the public client API and writes
nothing but its own summary line on stdout. The one source edit in the tree is the M2 build fix
(`private/deps-fix.patch`: a `(K[])` cast in `InputSampler.java`, a MapReduce partitioner
backport far off the failure path, required by javac 8).

## Caveats

* Single host: master, three regionservers, ZooKeeper and the clients share one two-core
  container, `hbase.rootdir` on the local filesystem rather than HDFS. HBase 0.90 warns about
  this (no append support on the local FS); it does not affect the assignment race, which is
  entirely between the master, ZooKeeper and the regionservers.
* The CPU limit and the four settings above are what make a small test cluster behave like a
  large, slow one. They shorten the master's patience; they do not alter the code path.
* The production noise log is HBase **1.2.7** while the reproduction is HBase **0.90.2-SNAPSHOT**
  — the shared per-system production log is fixed by the methodology and is the same file every
  HBase bug merges into.
* The storm is heavy (thousands of failed bring-ups). A single occurrence is enough to
  demonstrate the defect; the count simply reflects 300 regions churning for ~2 minutes.
