#!/usr/bin/env bash
# HBase-4078 reproduction — runs inside the per-bug container
#   docker run --rm -v "$PWD:/work" -v hbase4078-m2:/root/.m2 \
#     --entrypoint bash clods-eval:HBase-HBase-4078 /work/evaluations/HBase/HBase-4078/reproduce.sh
#
# Brings up a real, distributed deployment built from the PRE-FIX tree
#   HDFS 1.0.4 (NameNode + 2 DataNodes)  <-  hbase.rootdir
#   ZooKeeper (HQuorumPeer) + HMaster + 2 RegionServers, all separate JVMs, root logger DEBUG
# runs an ordinary read/write workload against it, and lets the filesystem be flaky for one
# bounded window (see private/repro/DistributedFileSystemImpl.java — a DistributedFileSystem
# subclass installed via fs.hdfs.impl that loses the tail of files written under a region's
# .tmp directory while a marker file exists).  NO HBase source is modified and NO log or
# print statement is added anywhere: everything in the captured log is HBase's own output.
#
# Output:  private/symptom.orig.log   (Log A: the standalone reproduction log)
#          private/merged.orig.log    (Log B: Log A merged into the shared production log)
# Detection is silent: assertions read the cluster's own reporting surfaces (HDFS listings,
# the servers' own logs, the client's results) and print only to this script's stdout.
set -uo pipefail

BUG_DIR=/work/evaluations/HBase/HBase-4078
SRC=/work/repos/HBase-HBase-4078
RUN=${RUN_DIR:-/work/repos/hbase4078-run}
TABLE=usertable
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export PATH=$JAVA_HOME/bin:$PATH
HADOOP_HOME=/opt/hadoop-1.0.4
NN_PORT=8020

say() { echo; echo "=== $* ==="; }
die() { echo "FATAL: $*" >&2; exit 1; }

############################################################################
say "0. build the pre-fix tree (idempotent)"
############################################################################
if [ ! -f "$SRC/target/hbase-0.93-SNAPSHOT.jar" ]; then
  (cd "$SRC" && mvn -B -DskipTests package \
     && mvn -B dependency:copy-dependencies -DincludeScope=test -DoutputDirectory=target/lib) \
     | tail -3
fi
[ -d "$SRC/target/classes" ] || die "no build at $SRC/target/classes"

if [ ! -d "$HADOOP_HOME" ]; then
  say "0b. fetch Hadoop 1.0.4 (the HDFS the pre-fix tree is built against)"
  curl -fsSL https://archive.apache.org/dist/hadoop/common/hadoop-1.0.4/hadoop-1.0.4.tar.gz \
    -o /tmp/hadoop.tgz || die "cannot download hadoop-1.0.4"
  tar xzf /tmp/hadoop.tgz -C /opt || die "cannot untar hadoop"
fi

############################################################################
say "1. clean layout + configuration"
############################################################################
pkill -f 'org.apache.hadoop.hbase' 2>/dev/null
pkill -f 'org.apache.hadoop.hdfs.server' 2>/dev/null
sleep 3
rm -rf "$RUN"
mkdir -p "$RUN"/{logs,hdfs/nn,hdfs/dn1,hdfs/dn2,zk,classes,conf-hadoop,conf-dn1,conf-dn2,conf-master,conf-rs1,conf-rs2,conf-client}

HDFS_URI="hdfs://localhost:$NN_PORT"

cat > "$RUN/conf-hadoop/core-site.xml" <<EOF
<?xml version="1.0"?><?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property><name>fs.default.name</name><value>$HDFS_URI</value></property>
  <property><name>hadoop.tmp.dir</name><value>$RUN/hdfs/tmp</value></property>
</configuration>
EOF
cat > "$RUN/conf-hadoop/hdfs-site.xml" <<EOF
<?xml version="1.0"?><?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property><name>dfs.name.dir</name><value>$RUN/hdfs/nn</value></property>
  <property><name>dfs.replication</name><value>2</value></property>
  <property><name>dfs.support.append</name><value>true</value></property>
  <property><name>dfs.datanode.max.xcievers</name><value>4096</value></property>
  <property><name>dfs.permissions</name><value>false</value></property>
</configuration>
EOF
cp "$RUN/conf-hadoop/core-site.xml" "$RUN/conf-dn1/"
cp "$RUN/conf-hadoop/core-site.xml" "$RUN/conf-dn2/"
for i in 1 2; do
  sed -e "s#<value>$RUN/hdfs/nn</value>#<value>$RUN/hdfs/nn</value>#" \
      "$RUN/conf-hadoop/hdfs-site.xml" > "$RUN/conf-dn$i/hdfs-site.xml"
  python3 - "$RUN/conf-dn$i/hdfs-site.xml" "$RUN/hdfs/dn$i" "$i" <<'PY'
import sys
p, datadir, i = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = open(p).read()
extra = """  <property><name>dfs.data.dir</name><value>%s</value></property>
  <property><name>dfs.datanode.address</name><value>0.0.0.0:%d</value></property>
  <property><name>dfs.datanode.ipc.address</name><value>0.0.0.0:%d</value></property>
  <property><name>dfs.datanode.http.address</name><value>0.0.0.0:%d</value></property>
</configuration>""" % (datadir, 50010 + i, 50020 + i, 50075 + i)
open(p, "w").write(s.replace("</configuration>", extra))
PY
done
cp "$RUN/conf-hadoop"/*.xml "$RUN/conf-master/" 2>/dev/null

# ---- HBase configuration (shared) ----------------------------------------
hbase_site() {   # $1 = regionserver port  $2 = info port
cat <<EOF
<?xml version="1.0"?><?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property><name>hbase.rootdir</name><value>$HDFS_URI/hbase</value></property>
  <property><name>hbase.cluster.distributed</name><value>true</value></property>
  <property><name>hbase.zookeeper.quorum</name><value>localhost</value></property>
  <property><name>hbase.zookeeper.property.dataDir</name><value>$RUN/zk</value></property>
  <property><name>hbase.zookeeper.property.clientPort</name><value>2181</value></property>
  <property><name>hbase.master.info.port</name><value>60010</value></property>
  <property><name>hbase.regionserver.port</name><value>$1</value></property>
  <property><name>hbase.regionserver.info.port</name><value>$2</value></property>
  <!-- keep one region for the table under test and make flush/compaction frequent
       enough that ordinary traffic produces several store files -->
  <property><name>hbase.hregion.max.filesize</name><value>10737418240</value></property>
  <property><name>hbase.hregion.memstore.flush.size</name><value>16777216</value></property>
  <property><name>hbase.hstore.compactionThreshold</name><value>6</value></property>
  <property><name>hbase.hstore.blockingStoreFiles</name><value>30</value></property>
  <property><name>hbase.server.thread.wakefrequency</name><value>2000</value></property>
  <property><name>hbase.regionserver.msginterval</name><value>1000</value></property>
  <property><name>hbase.master.wait.on.regionservers.mintostart</name><value>2</value></property>
  <property><name>dfs.support.append</name><value>true</value></property>
  <property><name>dfs.replication</name><value>2</value></property>
  <!-- the filesystem the servers talk to (see private/repro) -->
  <property><name>fs.hdfs.impl</name><value>org.apache.hadoop.hdfs.DistributedFileSystemImpl</value></property>
</configuration>
EOF
}
log4j_props() {  # $1 = log file name
cat <<EOF
log4j.rootLogger=DEBUG, FILE
log4j.threshold=ALL
log4j.appender.FILE=org.apache.log4j.FileAppender
log4j.appender.FILE.File=$RUN/logs/$1
log4j.appender.FILE.layout=org.apache.log4j.PatternLayout
log4j.appender.FILE.layout.ConversionPattern=%d{ISO8601} %-5p [%t] %c: %m%n
log4j.logger.org.apache.zookeeper=INFO
log4j.logger.org.apache.hadoop.ipc.HBaseServer.trace=INFO
log4j.logger.org.apache.hadoop.hbase.zookeeper=INFO
EOF
}
hbase_site 60020 60030 > "$RUN/conf-master/hbase-site.xml"
hbase_site 60020 60030 > "$RUN/conf-rs1/hbase-site.xml"
hbase_site 60021 60031 > "$RUN/conf-rs2/hbase-site.xml"
hbase_site 60020 60030 > "$RUN/conf-client/hbase-site.xml"
log4j_props hbase-master.log     > "$RUN/conf-master/log4j.properties"
log4j_props hbase-regionserver-1.log > "$RUN/conf-rs1/log4j.properties"
log4j_props hbase-regionserver-2.log > "$RUN/conf-rs2/log4j.properties"
log4j_props hbase-client.log     > "$RUN/conf-client/log4j.properties"
for d in conf-master conf-rs1 conf-rs2 conf-client; do
  cp "$RUN/conf-hadoop/core-site.xml" "$RUN/$d/" 2>/dev/null
done

HBASE_CP="$SRC/target/classes:$SRC/target/lib/*:$RUN/classes"

############################################################################
say "2. compile the harness (fault-injecting filesystem + workload client)"
############################################################################
javac -nowarn -cp "$SRC/target/classes:$SRC/target/lib/*" -d "$RUN/classes" \
  "$BUG_DIR/private/repro/DistributedFileSystemImpl.java" \
  "$BUG_DIR/private/repro/Client.java" || die "harness will not compile"

MARKER=$RUN/incident.arm
RECORD=$RUN/incident.record
: > "$RECORD"
CHAOS_OPTS="-Dhdfs.incident.marker=$MARKER -Dhdfs.incident.record=$RECORD -Dhdfs.incident.keep=0.55"

############################################################################
say "3. start HDFS (NameNode + 2 DataNodes)"
############################################################################
export HADOOP_CONF_DIR=$RUN/conf-hadoop
export HADOOP_LOG_DIR=$RUN/logs
export HADOOP_PID_DIR=$RUN/pids
mkdir -p "$HADOOP_PID_DIR"
echo "export JAVA_HOME=$JAVA_HOME" > "$RUN/conf-hadoop/hadoop-env.sh"
"$HADOOP_HOME/bin/hadoop" namenode -format -force > "$RUN/logs/format.out" 2>&1 \
  || die "namenode format failed (see $RUN/logs/format.out)"
nohup "$HADOOP_HOME/bin/hadoop" namenode > "$RUN/logs/namenode.out" 2>&1 &
for i in 1 2; do
  HADOOP_CONF_DIR=$RUN/conf-dn$i HADOOP_IDENT_STRING=dn$i \
    nohup "$HADOOP_HOME/bin/hadoop" datanode > "$RUN/logs/datanode$i.out" 2>&1 &
done
for i in $(seq 1 60); do
  if "$HADOOP_HOME/bin/hadoop" dfs -ls / >/dev/null 2>&1; then break; fi
  sleep 2
done
"$HADOOP_HOME/bin/hadoop" dfsadmin -report 2>/dev/null | head -12
"$HADOOP_HOME/bin/hadoop" dfs -ls / >/dev/null 2>&1 || die "HDFS did not come up"
"$HADOOP_HOME/bin/hadoop" dfs -mkdir /hbase 2>/dev/null

############################################################################
say "4. start ZooKeeper, HMaster and two RegionServers (separate JVMs)"
############################################################################
start_hbase_daemon() {   # $1 = conf dir  $2 = class  $3 = log file  $4.. = args
  local conf=$1 cls=$2 logfile=$3; shift 3
  nohup java -Xmx1500m \
    -Dhbase.log.dir="$RUN/logs" -Dhbase.log.file="$logfile" \
    -Dhbase.home.dir="$SRC" -Dhbase.id.str=clods -Dhbase.root.logger=DEBUG,FILE \
    -Dlog4j.configuration="file:$RUN/$conf/log4j.properties" \
    $CHAOS_OPTS \
    -cp "$RUN/$conf:$HBASE_CP" "$cls" "$@" \
    > "$RUN/logs/$logfile.out" 2>&1 &
  echo $!
}
ZK_PID=$(start_hbase_daemon conf-master org.apache.hadoop.hbase.zookeeper.HQuorumPeer zookeeper.log start)
sleep 8
MASTER_PID=$(start_hbase_daemon conf-master org.apache.hadoop.hbase.master.HMaster hbase-master.log start)
sleep 12
RS1_PID=$(start_hbase_daemon conf-rs1 org.apache.hadoop.hbase.regionserver.HRegionServer hbase-regionserver-1.log start)
RS2_PID=$(start_hbase_daemon conf-rs2 org.apache.hadoop.hbase.regionserver.HRegionServer hbase-regionserver-2.log start)
echo "zk=$ZK_PID master=$MASTER_PID rs1=$RS1_PID rs2=$RS2_PID"

client() {   # run the workload/admin client
  java -Dlog4j.configuration="file:$RUN/conf-client/log4j.properties" \
       -Dhbase.log.dir="$RUN/logs" -Dhbase.log.file=hbase-client.log $CHAOS_OPTS \
       -cp "$RUN/conf-client:$HBASE_CP" clods.Client "$@"
}

say "4b. wait for the cluster to become operational"
ok=no
for i in $(seq 1 60); do
  if client where -ROOT- >/dev/null 2>&1 || client create "$TABLE" >/dev/null 2>&1; then ok=yes; break; fi
  sleep 3
done
[ "$ok" = yes ] || { tail -40 "$RUN/logs/hbase-master.log"; die "cluster did not come up"; }
client create "$TABLE"
sleep 3
client where "$TABLE"

############################################################################
say "5. PHASE A — ordinary traffic on a healthy filesystem"
############################################################################
# three write batches, each followed by an operator flush, so the store ends up with
# several real store files; a mixed read/write workload runs against it afterwards.
for batch in 0 1 2 3; do
  client load "$TABLE" 3 9000 $((batch * 9000))
  client flush "$TABLE"
  sleep 6
done
client mixed "$TABLE" 4 45 36000
client count "$TABLE"
say "5b. store files after phase A"
client storefiles "$TABLE"

############################################################################
say "6. PHASE B — the filesystem incident"
############################################################################
# The window is opened, ordinary traffic keeps running, and the two operations that write a
# new store file (a compaction and a memstore flush) happen inside it.
client mixed "$TABLE" 3 20 36000 &
MIXED_PID=$!
touch "$MARKER"
echo "--- incident window OPEN at $(date -u +%FT%TZ)"

client majorcompact "$TABLE"
sleep 45
echo "--- files affected so far:"; cat "$RECORD"
client storefiles "$TABLE"

client load "$TABLE" 2 6000 40000
client flush "$TABLE"
sleep 30
echo "--- files affected in the window:"; cat "$RECORD"

rm -f "$MARKER"
echo "--- incident window CLOSED at $(date -u +%FT%TZ)"
wait $MIXED_PID 2>/dev/null

############################################################################
say "7. PHASE C — aftermath: the region is opened again"
############################################################################
sleep 20
say "7a. cluster state"
client where "$TABLE" || true
jps 2>/dev/null | grep -c HRegionServer || true

# if a regionserver went down, bring a replacement up (ordinary operator action)
if ! kill -0 "$RS1_PID" 2>/dev/null; then
  echo "--- regionserver 1 is gone; restarting it"
  RS1_PID=$(start_hbase_daemon conf-rs1 org.apache.hadoop.hbase.regionserver.HRegionServer hbase-regionserver-1.log start)
  sleep 25
fi
if ! kill -0 "$RS2_PID" 2>/dev/null; then
  echo "--- regionserver 2 is gone; restarting it"
  RS2_PID=$(start_hbase_daemon conf-rs2 org.apache.hadoop.hbase.regionserver.HRegionServer hbase-regionserver-2.log start)
  sleep 25
fi

client mixed "$TABLE" 3 20 36000
say "7b. move the region to the other server (ordinary operator action)"
client move "$TABLE" || true
sleep 25
client where "$TABLE" || true
client mixed "$TABLE" 3 20 36000
say "7c. move it back"
client move "$TABLE" || true
sleep 25
client mixed "$TABLE" 2 15 36000
client count "$TABLE" || true

############################################################################
say "8. OBSERVATIONS (assertions — read the cluster's own reporting surfaces)"
############################################################################
echo "--- files the filesystem cut short during the incident window:"
cat "$RECORD"
echo "--- what is in the table's column-family directory now:"
client storefiles "$TABLE" | tee "$RUN/storefiles.after.txt"

AFFECTED=$(awk '{print $1}' "$RECORD" | sed 's#.*/##' | sort -u)
echo "--- assertion 1: every cut-short file was moved out of .tmp into the store directory"
A1=ok
for f in $AFFECTED; do
  if grep -q "/$f " "$RUN/storefiles.after.txt" && ! grep -q "/$f .* TMP" "$RUN/storefiles.after.txt"; then
    echo "    $f : promoted into the column-family directory"
  else
    # the compaction/flush output may have been renamed on promotion; check by size
    echo "    $f : NOT found under its own name in the store dir"
    A1=check
  fi
done
echo "    assertion 1: $A1"

echo "--- assertion 2: the servers report these files as unusable, on every open"
grep -c "Failed open of" "$RUN"/logs/hbase-regionserver-*.log 2>/dev/null
grep -h "Failed open of" "$RUN"/logs/hbase-regionserver-*.log 2>/dev/null | head -8

echo "--- assertion 3: region open / compaction errors in the servers' logs"
grep -hc "Compaction failed\|Compaction Request failed\|ABORTING\|DroppedSnapshot" \
  "$RUN"/logs/hbase-regionserver-*.log 2>/dev/null

############################################################################
say "9. collect the reproduction log (Log A)"
############################################################################
mkdir -p "$BUG_DIR/private"
OUT=$BUG_DIR/private/symptom.orig.log
: > "$OUT"
for f in "$RUN"/logs/hbase-master.log "$RUN"/logs/hbase-regionserver-1.log \
         "$RUN"/logs/hbase-regionserver-2.log "$RUN"/logs/hbase-client.log; do
  [ -s "$f" ] || continue
  echo "===== $(basename "$f" .log)__var_log_hbase__$(basename "$f") =====" >> "$OUT"
  cat "$f" >> "$OUT"
done
ls -la "$OUT"
wc -l "$OUT"

say "10. merge the reproduction into the shared production log (Log B)"
PROD=/work/production-logs/HBase/production.log
if [ -s "$PROD" ]; then
  python3 "$BUG_DIR/private/merge_logs.py" --production "$PROD" --repro "$OUT" \
    --out "$BUG_DIR/private/merged.orig.log" --interleave position
  ls -la "$BUG_DIR/private/merged.orig.log"
else
  echo "no production log for HBase — merge skipped"
fi

say "DONE"
