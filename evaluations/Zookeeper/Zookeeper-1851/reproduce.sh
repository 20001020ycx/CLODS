#!/usr/bin/env bash
# reproduce.sh — Zookeeper-1851
#
# Symptom: a client connected to a non-leader member of the ensemble issues a create that
# asks for the new node's Stat back; the call never completes, that member stops answering
# every client on it, and the node is never created.
#
# Runs INSIDE the per-bug container:
#   docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1851 \
#       -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1851/reproduce.sh'
#
# What it does — all of it real system activity, nothing injected into the logs:
#   1. builds the pre-fix tree if needed (`ant jar`);
#   2. starts a REAL 3-node ZooKeeper ensemble from that build, root logger at DEBUG;
#   3. discovers which member is the leader and which are followers with the server's own
#      `srvr` four-letter-word command;
#   4. drives REAL client traffic through the REAL client API (org.apache.zookeeper.ZooKeeper)
#      and the REAL zkCli shell:
#        - two `normal` workloads (hundreds of create/getData/setData/exists/getChildren/
#          delete ops) against the leader and against follower #2,
#        - a zkCli shell session against the leader,
#        - a `collateral` client pinned to follower #1 doing ordinary ephemeral-node work
#          for the whole window,
#        - and finally, on follower #1, an ordinary session that does a plain create
#          (control) and then ONE create that asks for the resulting Stat  <-- the failing op;
#   5. concatenates the three servers' own DEBUG logs and the client session logs into
#      private/symptom.orig.log (the only added text is a "===== file: X =====" header per
#      collected file);
#   6. DETECTS the failure with silent assertions read from the clients' result files and
#      from the servers' own logs. Assertion output goes to reproduce.sh's stdout — it is
#      NEVER written into the symptom log.
#
# NO print/log statement is added to ZooKeeper anywhere. Workload.java (the client driver)
# writes nothing to stdout/stderr: its observations go to per-client result files that are
# not part of the symptom log.
set -euo pipefail

REPO="${REPO:-/work/repos/Zookeeper-Zookeeper-1851}"
BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1851}"
CPORT_BASE="${CPORT_BASE:-24551}"   # client ports 24551/24552/24553
QPORT_BASE="${QPORT_BASE:-24561}"   # quorum ports 24561/24562/24563
EPORT_BASE="${EPORT_BASE:-24571}"   # election ports 24571/24572/24573
APORT_BASE="${APORT_BASE:-24581}"   # admin (jetty) ports 24581/24582/24583
OUT_LOG="${OUT_LOG:-$BUG_DIR/private/symptom.orig.log}"   # where the collected log lands

RUN="$(mktemp -d /tmp/zk-repro-XXXX)"   # neutral: the JVM prints paths into the log
mkdir -p "$BUG_DIR/private" "$BUG_DIR/logs"

# ---- 1. build (idempotent) ------------------------------------------------------------
cd "$REPO"
if [ ! -d build/classes ]; then
    ant jar
fi
CP="$REPO/conf:$REPO/build/classes"
for j in "$REPO"/build/lib/*.jar; do CP="$CP:$j"; done

JVM_LOG_OPTS=(-Dzookeeper.log.dir="$RUN" -Dzookeeper.root.logger=DEBUG,CONSOLE
              -Dzookeeper.console.threshold=DEBUG)

# ---- 2. a real 3-node ensemble ---------------------------------------------------------
for i in 1 2 3; do
    mkdir -p "$RUN/data$i"
    echo "$i" > "$RUN/data$i/myid"
    cat > "$RUN/zoo$i.cfg" <<CFG
tickTime=2000
initLimit=10
syncLimit=5
dataDir=$RUN/data$i
clientPort=$((CPORT_BASE + i - 1))
server.1=127.0.0.1:$((QPORT_BASE)):$((EPORT_BASE))
server.2=127.0.0.1:$((QPORT_BASE + 1)):$((EPORT_BASE + 1))
server.3=127.0.0.1:$((QPORT_BASE + 2)):$((EPORT_BASE + 2))
CFG
    java "${JVM_LOG_OPTS[@]}" -Dzookeeper.admin.serverPort=$((APORT_BASE + i - 1)) \
         -cp "$CP" org.apache.zookeeper.server.quorum.QuorumPeerMain "$RUN/zoo$i.cfg" \
         > "$RUN/server_$i.log" 2>&1 &
    eval "SERVER_PID_$i=$!"
done
cleanup() {
    for i in 1 2 3; do
        eval "p=\${SERVER_PID_$i:-}"
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
}
trap cleanup EXIT

fourlw() {  # fourlw <clientPort> <word>  -> prints the server's reply
    local port="$1" word="$2"
    (exec 3<>/dev/tcp/127.0.0.1/"$port" && printf '%s' "$word" >&3 && timeout 3 cat <&3) 2>/dev/null || true
}

# wait for all three to answer ruok
for i in 1 2 3; do
    port=$((CPORT_BASE + i - 1))
    for _ in $(seq 1 90); do
        [ "$(fourlw "$port" ruok)" = "imok" ] && break
        sleep 1
    done
done

# ---- 3. ask the servers who leads (their own srvr command) -----------------------------
LEADER_PORT=""; FOLLOWER_PORTS=()
for _ in $(seq 1 60); do
    LEADER_PORT=""; FOLLOWER_PORTS=()
    for i in 1 2 3; do
        port=$((CPORT_BASE + i - 1))
        mode="$(fourlw "$port" srvr | grep -i '^Mode:' | awk '{print $2}' || true)"
        case "$mode" in
            leader)   LEADER_PORT="$port" ;;
            follower) FOLLOWER_PORTS+=("$port") ;;
        esac
    done
    [ -n "$LEADER_PORT" ] && [ "${#FOLLOWER_PORTS[@]}" -eq 2 ] && break
    sleep 1
done
if [ -z "$LEADER_PORT" ] || [ "${#FOLLOWER_PORTS[@]}" -ne 2 ]; then
    echo "[reproduce] ASSERT FAIL: ensemble did not settle (leader='$LEADER_PORT' followers='${FOLLOWER_PORTS[*]:-}')"
    exit 1
fi
F1="${FOLLOWER_PORTS[0]}"   # the member the failing client talks to
F2="${FOLLOWER_PORTS[1]}"
echo "[reproduce] ensemble up: leader=127.0.0.1:$LEADER_PORT followers=127.0.0.1:$F1,127.0.0.1:$F2"

# ---- 4. real client traffic ------------------------------------------------------------
mkdir -p "$RUN/wl"
javac -cp "$CP" -d "$RUN/wl" "$BUG_DIR/private/repro/Workload.java" 2>"$RUN/javac.log"
WLCP="$RUN/wl:$CP"

workload() {  # workload <name> <connect> <root> <n> <mode>
    timeout 180 java "${JVM_LOG_OPTS[@]}" -cp "$WLCP" Workload \
        "$2" "$3" "$4" "$5" "$RUN/result_$1.txt" > "$RUN/client_$1.log" 2>&1
}

# 4a. a client pinned to follower #1 that keeps doing ordinary work for the whole window
workload c2 "127.0.0.1:$F1" /app/svc2 45 collateral &
C2_PID=$!

# 4b. ordinary read/write traffic against the leader and against follower #2
workload c1 "127.0.0.1:$LEADER_PORT" /app/svc1 120 normal &
C1_PID=$!
workload c3 "127.0.0.1:$F2" /app/svc3 120 normal &
C3_PID=$!

# 4c. a real zkCli shell session against the leader, doing shell-level work
{
  echo "ls /"
  for i in $(seq 1 40); do
      echo "create /app/cfg-$i cfg-payload-$i"
      echo "get /app/cfg-$i"
      echo "set /app/cfg-$i cfg-payload-$i-v2"
      echo "stat /app/cfg-$i"
  done
  echo "ls /app"
  for i in $(seq 1 20); do echo "delete /app/cfg-$i"; done
  echo "quit"
} > "$RUN/cmds_shell.txt"
java "${JVM_LOG_OPTS[@]}" -cp "$CP" org.apache.zookeeper.ZooKeeperMain \
     -server "127.0.0.1:$LEADER_PORT" < "$RUN/cmds_shell.txt" > "$RUN/client_shell.log" 2>&1 || true

wait $C1_PID || true
wait $C3_PID || true

# 4d. the failing session: ordinary client on follower #1, plain create then create-with-stat
set +e
workload c4 "127.0.0.1:$F1" /app/svc4 1 createstat
C4_RC=$?
set -e
echo "[reproduce] target session exit code: $C4_RC"

wait $C2_PID || true

# 4e. from a client on the leader, check whether the node the failing client asked for exists
{
  echo "stat /app/svc4/item-9137"
  echo "ls /app/svc4"
  echo "quit"
} > "$RUN/cmds_check.txt"
java "${JVM_LOG_OPTS[@]}" -cp "$CP" org.apache.zookeeper.ZooKeeperMain \
     -server "127.0.0.1:$LEADER_PORT" < "$RUN/cmds_check.txt" > "$RUN/client_check.log" 2>&1 || true

sleep 2
cleanup
sleep 1

# ---- 5. assemble the symptom log (system output only) ----------------------------------
OUT="$OUT_LOG"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
# Collection headers use the same host__path convention as the shared production log, so
# the merged log reads as one collection. No header names a session "failing".
emit() {  # emit <file> <header-label>
    [ -f "$RUN/$1" ] || return 0
    printf '===== %s =====\n' "$2" >> "$OUT"
    cat "$RUN/$1" >> "$OUT"
}
emit server_1.log      zk11__var_log_zookeeper__zookeeper.log
emit server_2.log      zk12__var_log_zookeeper__zookeeper.log
emit server_3.log      zk13__var_log_zookeeper__zookeeper.log
emit client_c1.log     app1__var_log_app__client.log
emit client_c3.log     app2__var_log_app__client.log
emit client_shell.log  app3__var_log_app__admin.log
emit client_c2.log     app4__var_log_app__client.log
emit client_c4.log     app5__var_log_app__client.log
emit client_check.log  app6__var_log_app__admin.log
echo "[reproduce] wrote $OUT ($(wc -l < "$OUT") lines)"
cp -a "$RUN"/result_*.txt "$BUG_DIR/private/" 2>/dev/null || true

# map port -> server index, for the assertions below
f1_idx=$((F1 - CPORT_BASE + 1))

# ---- 6. silent detection (assertion output never enters the symptom log) ---------------
FAILED=0
RES_FAIL="$RUN/result_c4.txt"

grep -q '^plain_create=OK' "$RES_FAIL" \
    || { echo "[reproduce] ASSERT FAIL: the control plain create did not succeed on the follower"; FAILED=1; }
grep -q '^create_with_stat=EXCEPTION' "$RES_FAIL" \
    || { echo "[reproduce] ASSERT FAIL: create-with-stat completed normally"; FAILED=1; }
grep -q 'Node does not exist: /app/svc4/item-9137' "$RUN/client_check.log" \
    || { echo "[reproduce] ASSERT FAIL: the node was created after all"; FAILED=1; }
grep -q 'unable to continue' "$RUN/server_$f1_idx.log" \
    || { echo "[reproduce] ASSERT FAIL: follower's request pipeline did not report a fatal downstream error"; FAILED=1; }
grep -q '^collateral_failed\|^collateral_ok' "$RUN/result_c2.txt" \
    || { echo "[reproduce] ASSERT FAIL: collateral client produced no result"; FAILED=1; }

echo "[reproduce] --- failing client result ---"; sed 's/^/[reproduce]   /' "$RES_FAIL"
echo "[reproduce] --- collateral client result ---"; sed 's/^/[reproduce]   /' "$RUN/result_c2.txt"

if [ "$FAILED" -eq 0 ]; then
    echo "[reproduce] REPRODUCED: create-with-stat against the follower never completed, the"
    echo "[reproduce]             follower's request pipeline died, and the node was not created."
    exit 0
else
    echo "[reproduce] NOT REPRODUCED"
    exit 1
fi
