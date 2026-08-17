#!/usr/bin/env bash
# Generate the per-daemon conf dirs for the HBase-3627 reproduction cluster.
#   mkconf.sh <RUNDIR> <NUM_RS>
# Produces <RUNDIR>/conf-zk, conf-master, conf-rs1..conf-rsN.
# Only ordinary operator-tunable settings are used; no HBase code is touched.
set -euo pipefail
RUN=${1:?rundir}
NRS=${2:-3}
HOST=$(hostname)

mkdir -p "$RUN"/{logs,pids,zk,hbase-root}

emit_site() {  # $1 = conf dir, $2 = extra properties
  cat > "$1/hbase-site.xml" <<XML
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property><name>hbase.rootdir</name><value>file://$RUN/hbase-root</value></property>
  <property><name>hbase.cluster.distributed</name><value>true</value></property>
  <property><name>hbase.tmp.dir</name><value>$RUN/tmp</value></property>

  <property><name>hbase.zookeeper.quorum</name><value>localhost</value></property>
  <property><name>hbase.zookeeper.property.clientPort</name><value>2181</value></property>
  <property><name>hbase.zookeeper.property.dataDir</name><value>$RUN/zk</value></property>
  <property><name>hbase.zookeeper.property.maxClientCnxns</name><value>300</value></property>
  <property><name>zookeeper.session.timeout</name><value>15000</value></property>

  <!-- Operator tuning: react quickly to a region that is slow to come online. -->
  <property><name>hbase.master.assignment.timeoutmonitor.timeout</name><value>${RIT_TIMEOUT:-2000}</value></property>
  <property><name>hbase.master.assignment.timeoutmonitor.period</name><value>${RIT_PERIOD:-500}</value></property>
  <!-- ...and do not sit on a cluster-wide assignment for the default 10 minutes before
       letting the regions-in-transition monitor do its fixup. -->
  <property><name>hbase.bulk.assignment.waiton.empty.rit</name><value>${BULK_WAIT:-2000}</value></property>

  <!-- A cluster whose compactions have fallen far behind: small memstore flushes and
       compaction switched off, so every region accumulates hundreds of store files and
       takes a long time to open. -->
  <property><name>hbase.hregion.memstore.flush.size</name><value>${FLUSH_SIZE:-262144}</value></property>
  <property><name>hbase.hstore.compactionThreshold</name><value>100000</value></property>
  <property><name>hbase.hstore.blockingStoreFiles</name><value>100000</value></property>
  <property><name>hbase.hregion.majorcompaction</name><value>0</value></property>
  <property><name>hbase.regionserver.global.memstore.upperLimit</name><value>0.9</value></property>
  <property><name>hbase.regionserver.global.memstore.lowerLimit</name><value>0.85</value></property>
  <property><name>hbase.regionserver.logroll.period</name><value>3600000</value></property>
  <property><name>hbase.regionserver.maxlogs</name><value>128</value></property>
  <property><name>hbase.regionserver.optionallogflushinterval</name><value>1000</value></property>
  <property><name>hbase.hregion.max.filesize</name><value>10737418240</value></property>
  <property><name>hbase.regionserver.handler.count</name><value>30</value></property>
  <property><name>hbase.regionserver.executor.openregion.threads</name><value>${OPEN_THREADS:-1}</value></property>
  <property><name>hbase.client.retries.number</name><value>10</value></property>
  <property><name>hbase.regionserver.msginterval</name><value>1000</value></property>
$2
</configuration>
XML
}

emit_log4j() {  # $1 = conf dir
  cat > "$1/log4j.properties" <<'PROPS'
# Verbose operator logging: everything at DEBUG into the daemon log file.
hbase.root.logger=DEBUG,console
hbase.log.dir=.
hbase.log.file=hbase.log

log4j.rootLogger=${hbase.root.logger}
log4j.threshold=ALL

log4j.appender.DRFA=org.apache.log4j.DailyRollingFileAppender
log4j.appender.DRFA.File=${hbase.log.dir}/${hbase.log.file}
log4j.appender.DRFA.DatePattern=.yyyy-MM-dd
log4j.appender.DRFA.layout=org.apache.log4j.PatternLayout
log4j.appender.DRFA.layout.ConversionPattern=%d{ISO8601} %-5p [%t] %c{2}: %m%n

log4j.appender.console=org.apache.log4j.ConsoleAppender
log4j.appender.console.target=System.err
log4j.appender.console.layout=org.apache.log4j.PatternLayout
log4j.appender.console.layout.ConversionPattern=%d{ISO8601} %-5p [%t] %c{2}: %m%n

log4j.logger.org.apache.hadoop.hbase=DEBUG
log4j.logger.org.apache.zookeeper=DEBUG
log4j.logger.org.apache.hadoop=DEBUG
log4j.logger.org.mortbay.log=WARN
PROPS
}

emit_env() {  # $1 = conf dir, $2 = ident string, $3 = heap MB
  cat > "$1/hbase-env.sh" <<ENV
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export HBASE_HEAPSIZE=$3
export HBASE_LOG_DIR=$RUN/logs
export HBASE_PID_DIR=$RUN/pids
export HBASE_IDENT_STRING=$2
export HBASE_MANAGES_ZK=false
export HBASE_ROOT_LOGGER=DEBUG,DRFA
export HBASE_OPTS="-XX:+UseConcMarkSweepGC"
ENV
  cp "$1/../conf-src/hadoop-metrics.properties" "$1/" 2>/dev/null || true
}

mkdir -p "$RUN/conf-zk" "$RUN/conf-master"
emit_site "$RUN/conf-zk" ""
emit_log4j "$RUN/conf-zk"; emit_env "$RUN/conf-zk" zk 512

emit_site "$RUN/conf-master" ""
emit_log4j "$RUN/conf-master"; emit_env "$RUN/conf-master" master 2000

for i in $(seq 1 "$NRS"); do
  d="$RUN/conf-rs$i"; mkdir -p "$d"
  emit_site "$d" "  <property><name>hbase.regionserver.port</name><value>$((60019 + i))</value></property>
  <property><name>hbase.regionserver.info.port</name><value>$((60029 + i))</value></property>"
  emit_log4j "$d"; emit_env "$d" "rs$i" "${RS_HEAP:-8000}"
done

echo "mkconf.sh: wrote conf dirs under $RUN (host=$HOST, ${NRS} regionservers)"
