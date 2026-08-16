#!/usr/bin/env bash
# reproduce.sh — Zookeeper-1900
#
# Symptom: after three of the four members of an ensemble are re-provisioned on empty
# storage, the surviving fourth member (an observer that kept its snapshot directory but
# whose transaction-log directory was repointed to a new, empty volume) never rejoins the
# ensemble. Every attempt dies, it cycles LOOKING -> OBSERVING forever, clients that talk
# to it are never served, and the process leaks one connection to the leader per attempt.
#
# Runs INSIDE the per-bug container:
#   docker run --rm -v "$PWD:/work" clods-eval:Zookeeper-Zookeeper-1900 \
#       -c 'bash /work/evaluations/Zookeeper/Zookeeper-1900/reproduce.sh'
#
# What it does — all of it real system activity, nothing injected into the logs:
#   PHASE A ("the deployment as it ran before"):
#     1. builds the pre-fix tree if needed (`ant jar`);
#     2. starts a REAL 4-node ZooKeeper ensemble from that build (3 participants + 1
#        observer), root logger at DEBUG, every node with snapshots (dataDir) and
#        transaction logs (dataLogDir) on separate directories, as production deployments
#        commonly do;
#     3. discovers leader/followers/observer with the servers' own `srvr` four-letter word;
#     4. drives REAL client traffic through the REAL client API and the REAL zkCli shell
#        until the ensemble has executed a few thousand transactions and the observer has
#        written several snapshots;
#     5. shuts the four servers down.
#   PHASE B (the operator action, no code involved):
#     6. the three participants are re-provisioned: brand-new, empty data/log directories.
#        The observer keeps its data (snapshot) directory but its `dataLogDir` is pointed
#        at a new, empty directory — the old transaction-log volume is gone.
#   PHASE C (the incident):
#     7. the three re-provisioned participants start, form a quorum and serve REAL client
#        traffic (workloads + a long-running client), so the cluster is genuinely live;
#     8. the observer starts and tries to rejoin. Its own logs show what happens; the
#        script samples its open-socket count and the number of sockets in CLOSE_WAIT
#        while it retries, and a client tries to use the observer as its server.
#   9. concatenates all four servers' own DEBUG logs (this deployment and the previous
#      one) and the client session logs into private/symptom.orig.log (the only added text
#      is a "===== file: X =====" header per collected file);
#  10. DETECTS the failure with silent assertions read from the servers' own logs, the
#      clients' result files and /proc. Assertion output goes to reproduce.sh's stdout —
#      it is NEVER written into the symptom log.
#
# NO print/log statement is added to ZooKeeper anywhere. Workload.java (the client driver)
# writes nothing to stdout/stderr: its observations go to per-client result files that are
# not part of the symptom log.
set -euo pipefail

REPO="${REPO:-/work/repos/Zookeeper-Zookeeper-1900}"
BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1900}"
CPORT_BASE="${CPORT_BASE:-24611}"   # client   ports 24611..24614
QPORT_BASE="${QPORT_BASE:-24621}"   # quorum   ports 24621..24624
EPORT_BASE="${EPORT_BASE:-24631}"   # election ports 24631..24634
APORT_BASE="${APORT_BASE:-24641}"   # admin (jetty) ports 24641..24644
PREV_OPS="${PREV_OPS:-280}"         # iterations per client in the previous deployment
PREV_CLIENTS="${PREV_CLIENTS:-6}"   # how many concurrent clients drive the previous deployment
NEW_OPS="${NEW_OPS:-120}"           # iterations per client in the re-provisioned cluster
WATCH_SECS="${WATCH_SECS:-40}"      # how long we watch the observer trying to rejoin
OUT_LOG="${OUT_LOG:-$BUG_DIR/private/symptom.orig.log}"   # where the collected log lands
# M4 renames the failure-path types, including QuorumPeerMain; the anonymized tree is run
# with MAIN_CLASS pointing at the renamed entry point.
MAIN_CLASS="${MAIN_CLASS:-org.apache.zookeeper.server.quorum.QuorumPeerMain}"

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

declare -A PIDS=()

write_cfg() {   # write_cfg <idx> <cfgpath> <datadir> <logdir>
    local i="$1" cfg="$2" data="$3" logd="$4"
    mkdir -p "$data" "$logd"
    echo "$i" > "$data/myid"
    {
        echo "tickTime=2000"
        echo "initLimit=10"
        echo "syncLimit=5"
        echo "snapCount=300"
        echo "dataDir=$data"
        echo "dataLogDir=$logd"
        echo "clientPort=$((CPORT_BASE + i - 1))"
        [ "$i" = "4" ] && echo "peerType=observer"
        echo "server.1=127.0.0.1:$((QPORT_BASE)):$((EPORT_BASE))"
        echo "server.2=127.0.0.1:$((QPORT_BASE + 1)):$((EPORT_BASE + 1))"
        echo "server.3=127.0.0.1:$((QPORT_BASE + 2)):$((EPORT_BASE + 2))"
        echo "server.4=127.0.0.1:$((QPORT_BASE + 3)):$((EPORT_BASE + 3)):observer"
    } > "$cfg"
}

start_node() { # start_node <idx> <cfgpath> <logfile>
    local i="$1" cfg="$2" log="$3"
    mkdir -p "$(dirname "$log")"
    java "${JVM_LOG_OPTS[@]}" -Dzookeeper.admin.serverPort=$((APORT_BASE + i - 1)) \
         -cp "$CP" "$MAIN_CLASS" "$cfg" \
         >> "$log" 2>&1 &
    PIDS[$i]=$!
}

stop_node() { # stop_node <idx>
    local i="$1" p="${PIDS[$i]:-}"
    [ -n "$p" ] || return 0
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
    unset 'PIDS[$i]'
}

cleanup() {
    for i in "${!PIDS[@]}"; do kill "${PIDS[$i]}" 2>/dev/null || true; done
}
trap cleanup EXIT

fourlw() {  # fourlw <clientPort> <word>  -> prints the server's reply
    local port="$1" word="$2"
    (exec 3<>/dev/tcp/127.0.0.1/"$port" && printf '%s' "$word" >&3 && timeout 3 cat <&3) 2>/dev/null || true
}

wait_quorum() { # wait_quorum -> sets LEADER_PORT / FOLLOWER_PORTS for participants 1..3
    LEADER_PORT=""; FOLLOWER_PORTS=()
    local _ i port mode
    for _ in $(seq 1 90); do
        LEADER_PORT=""; FOLLOWER_PORTS=()
        for i in 1 2 3; do
            port=$((CPORT_BASE + i - 1))
            mode="$(fourlw "$port" srvr | grep -i '^Mode:' | awk '{print $2}' || true)"
            case "$mode" in
                leader)   LEADER_PORT="$port" ;;
                follower) FOLLOWER_PORTS+=("$port") ;;
            esac
        done
        [ -n "$LEADER_PORT" ] && [ "${#FOLLOWER_PORTS[@]}" -eq 2 ] && return 0
        sleep 1
    done
    return 1
}

workload() {  # workload <name> <connect> <root> <n> <mode> <logdir>
    timeout 600 java "${JVM_LOG_OPTS[@]}" -cp "$WLCP" Workload \
        "$2" "$3" "$4" "$5" "$RUN/result_$1.txt" > "$6/client_$1.log" 2>&1
}

########################################################################################
# PHASE A — the deployment as it ran before
########################################################################################
echo "[reproduce] PHASE A: starting the original 4-node ensemble (3 participants + 1 observer)"
mkdir -p "$RUN/logs/previous-deployment"
for i in 1 2 3 4; do
    write_cfg "$i" "$RUN/conf-prev-zoo$i.cfg" "$RUN/hosts/zk$i/data" "$RUN/hosts/zk$i/txnlog"
    start_node "$i" "$RUN/conf-prev-zoo$i.cfg" "$RUN/logs/previous-deployment/server_$i.log"
done

for i in 1 2 3 4; do
    port=$((CPORT_BASE + i - 1))
    for _ in $(seq 1 90); do
        [ "$(fourlw "$port" ruok)" = "imok" ] && break
        sleep 1
    done
done
if ! wait_quorum; then
    echo "[reproduce] ASSERT FAIL: the original ensemble never settled"
    exit 1
fi
OBS_MODE="$(fourlw $((CPORT_BASE + 3)) srvr | grep -i '^Mode:' | awk '{print $2}' || true)"
echo "[reproduce] previous deployment up: leader=$LEADER_PORT followers=${FOLLOWER_PORTS[*]} node4 mode=$OBS_MODE"
if [ "$OBS_MODE" != "observer" ]; then
    echo "[reproduce] ASSERT FAIL: node 4 is not an observer (mode=$OBS_MODE)"
    exit 1
fi

# real client traffic against the previous deployment
mkdir -p "$RUN/wl"
javac -cp "$CP" -d "$RUN/wl" "$BUG_DIR/private/repro/Workload.java" 2>"$RUN/javac.log"
WLCP="$RUN/wl:$CP"

PREV_WL_PIDS=()
PREV_TARGETS=("$LEADER_PORT" "${FOLLOWER_PORTS[0]}" "${FOLLOWER_PORTS[1]}")
for c in $(seq 1 "$PREV_CLIENTS"); do
    tgt="${PREV_TARGETS[$(( (c - 1) % 3 ))]}"
    workload "prev_wl$c" "127.0.0.1:$tgt" "/app/prev-$c" "$PREV_OPS" normal \
             "$RUN/logs/previous-deployment" &
    PREV_WL_PIDS+=($!)
done

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
     -server "127.0.0.1:$LEADER_PORT" < "$RUN/cmds_shell.txt" \
     > "$RUN/logs/previous-deployment/client_prev_shell.log" 2>&1 || true

for p in "${PREV_WL_PIDS[@]}"; do wait "$p" || true; done

# a client that reads through the observer, so it is genuinely in use
workload prev_observer_reads "127.0.0.1:$((CPORT_BASE + 3))" /app/prev-obs 10 collateral \
         "$RUN/logs/previous-deployment" || true

sleep 3
echo "[reproduce] previous deployment: stopping all four members"
for i in 1 2 3 4; do stop_node "$i"; done
sleep 2

PREV_SNAPS=$(ls "$RUN/hosts/zk4/data/version-2/" 2>/dev/null | grep -c '^snapshot\.' || true)
PREV_LOGS=$(ls "$RUN/hosts/zk4/txnlog/version-2/" 2>/dev/null | grep -c '^log\.' || true)
OBS_LAST_SNAP=$(ls "$RUN/hosts/zk4/data/version-2/" 2>/dev/null | grep '^snapshot\.' | sort | tail -1 || true)
echo "[reproduce] observer state after the previous deployment: $PREV_SNAPS snapshots, $PREV_LOGS txn logs, newest snapshot=$OBS_LAST_SNAP"

########################################################################################
# PHASE B — the operator action (no ZooKeeper code involved)
########################################################################################
# The three participants are re-provisioned on empty storage. The observer machine is
# left alone except that its transaction-log volume is replaced: dataLogDir now points at
# a new, empty directory, while dataDir (its snapshots) is untouched.
echo "[reproduce] PHASE B: re-provisioning participants 1-3; observer keeps dataDir, gets a new empty dataLogDir"
for i in 1 2 3; do
    write_cfg "$i" "$RUN/conf-new-zoo$i.cfg" "$RUN/hosts/zk$i/data-vol2" "$RUN/hosts/zk$i/txnlog-vol2"
done
write_cfg 4 "$RUN/conf-new-zoo4.cfg" "$RUN/hosts/zk4/data" "$RUN/hosts/zk4/txnlog-vol2"

########################################################################################
# PHASE C — the incident
########################################################################################
echo "[reproduce] PHASE C: starting the three re-provisioned participants"
for i in 1 2 3; do
    start_node "$i" "$RUN/conf-new-zoo$i.cfg" "$RUN/logs/server_$i.log"
done
for i in 1 2 3; do
    port=$((CPORT_BASE + i - 1))
    for _ in $(seq 1 90); do
        [ "$(fourlw "$port" ruok)" = "imok" ] && break
        sleep 1
    done
done
if ! wait_quorum; then
    echo "[reproduce] ASSERT FAIL: the re-provisioned cluster never settled"
    exit 1
fi
echo "[reproduce] new cluster up: leader=$LEADER_PORT followers=${FOLLOWER_PORTS[*]}"

# real client traffic on the live cluster
workload new_leaderwl "127.0.0.1:$LEADER_PORT" /app/new-a "$NEW_OPS" normal "$RUN/logs" &
NEW_WL1=$!
workload new_followerwl "127.0.0.1:${FOLLOWER_PORTS[0]}" /app/new-b "$NEW_OPS" normal "$RUN/logs" &
NEW_WL2=$!
wait $NEW_WL1 || true
wait $NEW_WL2 || true

# a client that keeps working against the quorum for the whole observation window
workload steady "127.0.0.1:$LEADER_PORT" /app/steady "$WATCH_SECS" collateral "$RUN/logs" &
STEADY_PID=$!

echo "[reproduce] starting the observer"
start_node 4 "$RUN/conf-new-zoo4.cfg" "$RUN/logs/server_4.log"
OBS_PID="${PIDS[4]}"

# sample the observer's resource usage while it retries (never written into the log)
SAMPLES="$RUN/observer_samples.txt"
: > "$SAMPLES"
(
  for s in $(seq 1 $((WATCH_SECS / 5))); do
      sleep 5
      fds=$(ls /proc/"$OBS_PID"/fd 2>/dev/null | wc -l || echo 0)
      socks=$(ls -l /proc/"$OBS_PID"/fd 2>/dev/null | grep -c 'socket:' || true)
      cw=$(ss -tan 2>/dev/null | grep -c 'CLOSE-WAIT' || true)
      printf 't=%3ds observer_open_fds=%s observer_sockets=%s close_wait_sockets=%s\n' \
             $((s * 5)) "$fds" "$socks" "$cw" >> "$SAMPLES"
  done
) &
SAMPLER_PID=$!

# after giving the observer a few attempts, ask it to serve an ordinary client
sleep 20
workload observer_probe "127.0.0.1:$((CPORT_BASE + 3))" /app/probe 1 probe "$RUN/logs" || true
OBS_STAT="$(fourlw $((CPORT_BASE + 3)) srvr || true)"
printf '%s\n' "$OBS_STAT" > "$RUN/result_observer_srvr.txt"

wait $SAMPLER_PID || true
wait $STEADY_PID || true

# what does the rest of the cluster think, and where is the leader's zxid?
{
  echo "ls /app"
  echo "stat /app/steady"
  echo "quit"
} > "$RUN/cmds_check.txt"
java "${JVM_LOG_OPTS[@]}" -cp "$CP" org.apache.zookeeper.ZooKeeperMain \
     -server "127.0.0.1:$LEADER_PORT" < "$RUN/cmds_check.txt" \
     > "$RUN/logs/client_check.log" 2>&1 || true
fourlw "$LEADER_PORT" srvr > "$RUN/result_leader_srvr.txt" || true

sleep 2
cleanup
sleep 1

########################################################################################
# 9. assemble the symptom log (system output only)
########################################################################################
OUT="$OUT_LOG"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
for f in logs/previous-deployment/server_1.log logs/previous-deployment/server_2.log \
         logs/previous-deployment/server_3.log logs/previous-deployment/server_4.log \
         logs/previous-deployment/client_prev_wl1.log \
         logs/previous-deployment/client_prev_wl2.log \
         logs/previous-deployment/client_prev_wl3.log \
         logs/previous-deployment/client_prev_wl4.log \
         logs/previous-deployment/client_prev_wl5.log \
         logs/previous-deployment/client_prev_wl6.log \
         logs/previous-deployment/client_prev_shell.log \
         logs/previous-deployment/client_prev_observer_reads.log \
         logs/server_1.log logs/server_2.log logs/server_3.log logs/server_4.log \
         logs/client_new_leaderwl.log logs/client_new_followerwl.log \
         logs/client_steady.log logs/client_observer_probe.log logs/client_check.log; do
    [ -f "$RUN/$f" ] || continue
    printf '===== file: %s =====\n' "$f" >> "$OUT"
    cat "$RUN/$f" >> "$OUT"
done
echo "[reproduce] wrote $OUT ($(wc -l < "$OUT") lines)"
cp -a "$RUN"/result_*.txt "$SAMPLES" "$BUG_DIR/private/" 2>/dev/null || true

########################################################################################
# 10. silent detection (assertion output never enters the symptom log)
########################################################################################
FAILED=0
OBS_LOG="$RUN/logs/server_4.log"

NPES=$(grep -c 'java.lang.NullPointerException' "$OBS_LOG" || true)
# the M4 rename swaps this vocabulary (truncate -> rollBack), so accept either wording
TRUNC_FRAMES=$(grep -cE '\.(truncate|rollBack)\((FileTxnLog|TxnJournal)\.java:' "$OBS_LOG" || true)
SYNC_ATTEMPTS=$(grep -cE '(Truncating log to get in sync with the leader|Rolling back the transaction log to get in sync with the leader|Rewinding the transaction journal to match the leader)' "$OBS_LOG" || true)
OBSERVING=$(grep -c '^.*OBSERVING' "$OBS_LOG" || true)
LEADER_SYNCS=$(grep -cE '(Synchronizing with Follower sid: 4|Bringing peer up to date, sid: 4)' "$RUN/logs/server_"*.log || true)

[ "$NPES" -ge 3 ] \
    || { echo "[reproduce] ASSERT FAIL: observer did not report repeated NullPointerExceptions (saw $NPES)"; FAILED=1; }
[ "$TRUNC_FRAMES" -ge 3 ] \
    || { echo "[reproduce] ASSERT FAIL: the failures are not in the transaction-log roll-back path (saw $TRUNC_FRAMES frames)"; FAILED=1; }
[ "$SYNC_ATTEMPTS" -ge 3 ] \
    || { echo "[reproduce] ASSERT FAIL: observer did not repeatedly try to sync with the leader (saw $SYNC_ATTEMPTS)"; FAILED=1; }
grep -q 'probe=EXCEPTION\|connect=TIMEOUT' "$RUN/result_observer_probe.txt" 2>/dev/null \
    || { echo "[reproduce] ASSERT FAIL: a client was served normally by the observer"; FAILED=1; }
grep -q 'steady_ok\|collateral_ok=' "$RUN/result_steady.txt" 2>/dev/null \
    || { echo "[reproduce] ASSERT FAIL: the steady client on the quorum produced no result"; FAILED=1; }

FIRST_SOCKS=$(head -1 "$SAMPLES" | sed 's/.*observer_sockets=\([0-9]*\).*/\1/')
LAST_SOCKS=$(tail -1 "$SAMPLES" | sed 's/.*observer_sockets=\([0-9]*\).*/\1/')
LAST_CW=$(tail -1 "$SAMPLES" | sed 's/.*close_wait_sockets=\([0-9]*\).*/\1/')
echo "[reproduce] observer sockets: first sample=$FIRST_SOCKS last sample=$LAST_SOCKS (CLOSE_WAIT in container: $LAST_CW)"

echo "[reproduce] --- counters ---"
echo "[reproduce]   NullPointerExceptions in the observer log : $NPES"
echo "[reproduce]   frames in FileTxnLog's roll-back method   : $TRUNC_FRAMES"
echo "[reproduce]   'get in sync with the leader' attempts    : $SYNC_ATTEMPTS"
echo "[reproduce]   leader-side syncs with sid 4              : $LEADER_SYNCS"
echo "[reproduce] --- observer srvr ---"; sed 's/^/[reproduce]   /' "$RUN/result_observer_srvr.txt" || true
echo "[reproduce] --- leader srvr ---";   sed 's/^/[reproduce]   /' "$RUN/result_leader_srvr.txt" || true
echo "[reproduce] --- observer probe ---"; sed 's/^/[reproduce]   /' "$RUN/result_observer_probe.txt" 2>/dev/null || true
echo "[reproduce] --- samples ---";        sed 's/^/[reproduce]   /' "$SAMPLES"

if [ "$FAILED" -eq 0 ]; then
    echo "[reproduce] REPRODUCED: the observer never rejoins — every attempt dies with a"
    echo "[reproduce]             NullPointerException, it retries forever, it cannot serve"
    echo "[reproduce]             clients, and it leaks a connection to the leader each time."
    exit 0
else
    echo "[reproduce] NOT REPRODUCED"
    exit 1
fi
