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
CPORT_BASE="${CPORT_BASE:-21851}"   # client ports 21851/21852/21853
QPORT_BASE="${QPORT_BASE:-21861}"   # quorum ports 21861/21862/21863
EPORT_BASE="${EPORT_BASE:-21871}"   # election ports 21871/21872/21873
APORT_BASE="${APORT_BASE:-21881}"   # admin (jetty) ports 21881/21882/21883

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
workload collateral "127.0.0.1:$F1" /app/collateral 45 collateral &
COLLATERAL_PID=$!

# 4b. ordinary read/write traffic against the leader and against follower #2
workload leaderwl "127.0.0.1:$LEADER_PORT" /app/leader 120 normal &
LEADER_WL_PID=$!
workload followerwl "127.0.0.1:$F2" /app/follower2 120 normal &
FOLLOWER_WL_PID=$!

# 4c. a real zkCli shell session against the leader, doing shell-level work
{
  echo "ls /"
  for i in $(seq 1 40); do
      echo "create /app/shell-$i shell-payload-$i"
      echo "get /app/shell-$i"
      echo "set /app/shell-$i shell-payload-$i-v2"
      echo "stat /app/shell-$i"
  done
  echo "ls /app"
  for i in $(seq 1 20); do echo "delete /app/shell-$i"; done
  echo "quit"
} > "$RUN/cmds_shell.txt"
java "${JVM_LOG_OPTS[@]}" -cp "$CP" org.apache.zookeeper.ZooKeeperMain \
     -server "127.0.0.1:$LEADER_PORT" < "$RUN/cmds_shell.txt" > "$RUN/client_shell.log" 2>&1 || true

wait $LEADER_WL_PID || true
wait $FOLLOWER_WL_PID || true

# 4d. the failing session: ordinary client on follower #1, plain create then create-with-stat
set +e
workload failing "127.0.0.1:$F1" /app/failing 1 createstat
FAILING_RC=$?
set -e
echo "[reproduce] failing session exit code: $FAILING_RC"

wait $COLLATERAL_PID || true

# 4e. from a client on the leader, check whether the node the failing client asked for exists
{
  echo "stat /app/failing/with-stat"
  echo "ls /app/failing"
  echo "quit"
} > "$RUN/cmds_check.txt"
java "${JVM_LOG_OPTS[@]}" -cp "$CP" org.apache.zookeeper.ZooKeeperMain \
     -server "127.0.0.1:$LEADER_PORT" < "$RUN/cmds_check.txt" > "$RUN/client_check.log" 2>&1 || true

sleep 2
cleanup
sleep 1

# ---- 5. assemble the symptom log (system output only) ----------------------------------
OUT="$BUG_DIR/private/symptom.orig.log"
: > "$OUT"
for f in server_1.log server_2.log server_3.log \
         client_leaderwl.log client_followerwl.log client_shell.log \
         client_collateral.log client_failing.log client_check.log; do
    [ -f "$RUN/$f" ] || continue
    printf '===== file: %s =====\n' "$f" >> "$OUT"
    cat "$RUN/$f" >> "$OUT"
done
echo "[reproduce] wrote $OUT ($(wc -l < "$OUT") lines)"
cp -a "$RUN"/result_*.txt "$BUG_DIR/private/" 2>/dev/null || true

# map port -> server index, for the assertions below
f1_idx=$((F1 - CPORT_BASE + 1))

# ---- 6. silent detection (assertion output never enters the symptom log) ---------------
FAILED=0
RES_FAIL="$RUN/result_failing.txt"

grep -q '^plain_create=OK' "$RES_FAIL" \
    || { echo "[reproduce] ASSERT FAIL: the control plain create did not succeed on the follower"; FAILED=1; }
grep -q '^create_with_stat=EXCEPTION' "$RES_FAIL" \
    || { echo "[reproduce] ASSERT FAIL: create-with-stat completed normally"; FAILED=1; }
grep -q 'Node does not exist: /app/failing/with-stat' "$RUN/client_check.log" \
    || { echo "[reproduce] ASSERT FAIL: the node was created after all"; FAILED=1; }
grep -q 'unable to continue' "$RUN/server_$f1_idx.log" \
    || { echo "[reproduce] ASSERT FAIL: follower's request pipeline did not report a fatal downstream error"; FAILED=1; }
grep -q '^collateral_failed\|^collateral_ok' "$RUN/result_collateral.txt" \
    || { echo "[reproduce] ASSERT FAIL: collateral client produced no result"; FAILED=1; }

echo "[reproduce] --- failing client result ---"; sed 's/^/[reproduce]   /' "$RES_FAIL"
echo "[reproduce] --- collateral client result ---"; sed 's/^/[reproduce]   /' "$RUN/result_collateral.txt"

if [ "$FAILED" -eq 0 ]; then
    echo "[reproduce] REPRODUCED: create-with-stat against the follower never completed, the"
    echo "[reproduce]             follower's request pipeline died, and the node was not created."
    exit 0
else
    echo "[reproduce] NOT REPRODUCED"
    exit 1
fi
