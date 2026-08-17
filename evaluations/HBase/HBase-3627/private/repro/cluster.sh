#!/usr/bin/env bash
# Start / stop the HBase-3627 reproduction cluster (1 master + N regionservers + 1 ZooKeeper),
# all built from the pre-fix source tree pointed at by $HBASE_SRC.
#   cluster.sh start <RUNDIR> <HBASE_SRC> <NUM_RS>
#   cluster.sh stop  <RUNDIR> <HBASE_SRC> <NUM_RS>
#   cluster.sh kill  <RUNDIR> rs<N>          # kill -9 one regionserver (chaos)
#   cluster.sh cp    <RUNDIR> <HBASE_SRC>    # print the client classpath
set -euo pipefail
CMD=${1:?start|stop|kill|cp}
RUN=${2:?rundir}
case "$CMD" in
  start|stop|cp) H=${3:?hbase src}; NRS=${4:-3};;
  kill) WHO=${3:?rsN};;
esac

case "$CMD" in
  start)
    export HBASE_HOME=$H
    HBASE_CONF_DIR=$RUN/conf-zk      $H/bin/hbase-daemon.sh --config "$RUN/conf-zk"     start zookeeper
    sleep 5
    HBASE_CONF_DIR=$RUN/conf-master  $H/bin/hbase-daemon.sh --config "$RUN/conf-master" start master
    sleep 8
    for i in $(seq 1 "$NRS"); do
      HBASE_CONF_DIR=$RUN/conf-rs$i  $H/bin/hbase-daemon.sh --config "$RUN/conf-rs$i"   start regionserver
    done
    sleep 12
    ;;
  stop)
    # Stop by pid file (hbase-daemon.sh stop blocks forever on an already-dead daemon).
    for p in "$RUN"/pids/*.pid; do
      [ -f "$p" ] || continue
      pid=$(cat "$p"); kill "$pid" 2>/dev/null || true
    done
    sleep 8
    # Fallback: the daemons carry -Dhbase.id.str= early in their command line (pgrep -f only
    # sees the first 4k chars, and the HBase class name sits behind a 3kB classpath). The
    # bracketed regex below does not match this script's own command line.
    for pid in $(pgrep -f 'hbase[.]id[.]str=' 2>/dev/null); do kill -9 "$pid" 2>/dev/null || true; done
    rm -f "$RUN"/pids/*.pid 2>/dev/null || true
    ;;
  kill)
    p="$RUN/pids/hbase-$WHO-regionserver.pid"
    [ -f "$p" ] || { echo "no pid file $p" >&2; exit 1; }
    kill -9 "$(cat "$p")" && rm -f "$p"
    echo "killed $WHO"
    ;;
  cp)
    export HBASE_HOME=$H
    HBASE_CONF_DIR=$RUN/conf-master $H/bin/hbase classpath 2>/dev/null
    ;;
esac
