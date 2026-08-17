#!/usr/bin/env bash
# HBASE-3627 reproduction — real HBase cluster, real client traffic, no code changes.
#
#   reproduce.sh [HBASE_SRC] [RUNDIR] [OUT_LOG]
#     HBASE_SRC  source tree to run (default /work/repos/HBase-HBase-3627 = the pre-fix tree;
#                at M4 this is pointed at the anonymized tree)
#     RUNDIR     scratch cluster dir     (default /work/repos/hbase-cluster-run; the path and the
#                container hostname must not contain the bug number - they end up in the log)
#     OUT_LOG    where the collected log is written
#                (default /work/evaluations/HBase/HBase-3627/private/symptom.orig.log)
#
# Run it INSIDE the per-bug container, which must be CPU-limited so that region opens are
# slow relative to the master's regions-in-transition timeout (an ordinary, overloaded
# two-core node):
#
#   docker run -d --name clods-hbase --hostname hbase-node-a --cpus=2 -v "$PWD:/work" \
#       -v "$PWD/repos/.m2-HBase-3627:/root/.m2" --entrypoint bash \
#       clods-eval:HBase-HBase-3627 -lc 'sleep infinity'
#   docker exec clods-hbase bash /work/evaluations/HBase/HBase-3627/reproduce.sh
#
# Scenario (all of it is ordinary operation — nothing is patched, no log line is injected):
#   PHASE A  a 3-regionserver cluster is brought up on one host, a 300-region user table is
#            created, ~3M rows of 1 KB are written and a mixed read/write/scan/delete
#            workload is run against it.  Compaction is switched off and the memstore flush
#            size is small, so the table ends up with a few hundred store files per region —
#            an ordinary "compactions have fallen behind" cluster, whose regions are
#            therefore slow to open.
#   PHASE B  the operator restarts the cluster (stop all daemons, start them again).  The
#            master bulk-assigns all 300 regions across the three regionservers far faster
#            than they can open them.
#   PHASE C  client traffic keeps running across the restart and after it.
#
# Detection is silent: the assertions below read the servers' own logs and the clients'
# result files and print ONLY to this script's stdout.  Nothing is written into any HBase
# log by this script or by the workload client.
set -euo pipefail

H=${1:-/work/repos/HBase-HBase-3627}
RUN=${2:-/work/repos/hbase-cluster-run}
OUT=${3:-/work/evaluations/HBase/HBase-3627/private/symptom.orig.log}
R=/work/evaluations/HBase/HBase-3627/private/repro
NRS=3
REGIONS=${REGIONS:-300}
LOAD_OPS=${LOAD_OPS:-250000}          # per thread, 12 threads -> 3M rows of 1 KB
export RIT_TIMEOUT=${RIT_TIMEOUT:-2000}
export RIT_PERIOD=${RIT_PERIOD:-500}
export OPEN_THREADS=${OPEN_THREADS:-1}

say() { echo "[$(date -u +%FT%T.%3NZ)] $*"; }

# ---------------------------------------------------------------- build (M2 command)
if [ ! -d "$H/target/classes" ]; then
  say "building $H from source"
  ( cd "$H" && mvn -q -DskipTests -Dmaven.javadoc.skip=true package )
fi

# ---------------------------------------------------------------- clean slate
bash "$R/cluster.sh" stop "$RUN" "$H" $NRS >/dev/null 2>&1 || true
rm -rf "$RUN"
bash "$R/mkconf.sh" "$RUN" $NRS
mkdir -p "$RUN"/{client-classes,client-logs,results}

# ---------------------------------------------------------------- PHASE A: healthy cluster
say "PHASE A: starting cluster ($NRS regionservers)"
bash "$R/cluster.sh" start "$RUN" "$H" $NRS >/dev/null 2>&1
grep -a "Master has completed initialization" "$RUN/logs/hbase-master-master-$(hostname).log" >/dev/null \
  || { echo "FAILED: master did not initialize"; exit 1; }

CP=$(bash "$R/cluster.sh" cp "$RUN" "$H")
javac -cp "$CP" -d "$RUN/client-classes" "$R/Workload.java" "$R/CreateTable.java"

say "PHASE A: creating the user table with $REGIONS regions"
java -cp "$RUN/client-classes:$CP" CreateTable usertable "$REGIONS" 2000000 \
  > "$RUN/results/create.txt" 2> "$RUN/client-logs/create.log"

say "PHASE A: loading ~$((LOAD_OPS * 12 / 1000))k rows"
java -Xmx4g -cp "$RUN/client-classes:$CP" Workload usertable 12 "$LOAD_OPS" 1024 load 2000000 \
  > "$RUN/results/load.txt" 2> "$RUN/client-logs/load.log"

say "PHASE A: steady-state mixed traffic"
java -Xmx2g -cp "$RUN/client-classes:$CP" Workload usertable 6 3000 1024 mixed 2000000 \
  > "$RUN/results/steady.txt" 2> "$RUN/client-logs/steady.log"

# ---------------------------------------------------------------- PHASE B/C: the incident
say "PHASE C: starting client traffic that runs across the restart"
nohup java -Xmx2g -cp "$RUN/client-classes:$CP" Workload usertable 6 20000 1024 mixed 2000000 \
  > "$RUN/results/during_incident.txt" 2> "$RUN/client-logs/during_incident.log" &
CLIENT=$!
sleep 5

say "PHASE B: operator restarts the cluster"
bash "$R/cluster.sh" stop "$RUN" "$H" $NRS >/dev/null 2>&1 || true
sleep 5
bash "$R/cluster.sh" start "$RUN" "$H" $NRS >/dev/null 2>&1

# let the assignment storm run its course: stop when no new regions-in-transition timeout
# has been logged for 45 s, or after 8 minutes.
MASTER_LOG="$RUN/logs/hbase-master-master-$(hostname).log"
say "PHASE B: waiting for the cluster to settle"
last=0; quiet=0; waited=0
while [ $waited -lt 480 ]; do
  sleep 15; waited=$((waited + 15))
  now=$(grep -acE "Regions in transition timed out|Placement did not finish in time" "$MASTER_LOG" || true)
  if [ "$now" = "$last" ]; then quiet=$((quiet + 15)); else quiet=0; fi
  last=$now
  [ $quiet -ge 45 ] && break
done
wait $CLIENT || true

say "PHASE C: post-incident probe traffic"
java -Xmx2g -cp "$RUN/client-classes:$CP" Workload usertable 4 500 1024 mixed 2000000 \
  > "$RUN/results/after.txt" 2> "$RUN/client-logs/after.log" || true

# ---------------------------------------------------------------- collect the log
say "collecting logs -> $OUT"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
for f in "$RUN"/logs-preincident/*.log "$RUN"/logs/*.log "$RUN"/client-logs/*.log; do
  [ -f "$f" ] || continue
  printf '===== file: %s =====\n' "$(basename "$f")" >> "$OUT"
  cat "$f" >> "$OUT"
done

# ---------------------------------------------------------------- silent assertions
echo
echo "================ reproduction result ================"
# The patterns accept both the pre-fix wording and the M4-anonymized wording, so the same
# script asserts the same failure before and after anonymization.
NPE=$(cat "$RUN"/logs/hbase-rs[123]-regionserver-*.log 2>/dev/null | grep -acE "(Caught throwable while processing event|Handler died on an unexpected error, task) (M_RS_OPEN_REGION|M_RS_BRINGUP_REGION)" || true)
STACK=$(cat "$RUN"/logs/hbase-rs[123]-regionserver-*.log 2>/dev/null | grep -acE "at org\.apache\.hadoop\.hbase\.zookeeper\.(ZKAssign|RegionStateZK)\.transitionNode" || true)
NONODE=$(cat "$RUN"/logs/hbase-rs[123]-regionserver-*.log 2>/dev/null | grep -acE "because node does not exist|since the node is absent" || true)
RIT=$(grep -acE "Regions in transition timed out|Placement did not finish in time" "$MASTER_LOG" || true)
echo "regions-in-transition timeouts logged by the master : $RIT"
echo "M_RS_OPEN_REGION handler failures on regionservers   : $NPE"
echo "  ...of which the stack passes through ZKAssign      : $STACK"
echo "znode reads that found no node                       : $NONODE"
echo "client results:"
for f in "$RUN"/results/*.txt; do printf '  %-22s %s\n' "$(basename "$f")" "$(cat "$f")"; done
echo "collected log: $(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1)"
echo "====================================================="
if [ "$NPE" -gt 0 ] && [ "$STACK" -gt 0 ]; then
  echo "REPRODUCED=true"
else
  echo "REPRODUCED=false"; exit 1
fi
