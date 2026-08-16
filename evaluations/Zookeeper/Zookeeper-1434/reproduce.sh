#!/usr/bin/env bash
# reproduce.sh — Zookeeper-1434 (zkCli dies with an unhandled NPE on the node-status
# command when the path does not exist).
#
# Runs INSIDE the per-bug container:
#   docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1434 \
#       -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1434/reproduce.sh'
#
# What it does (all of it real system activity — nothing is injected into the logs):
#   1. builds the pre-fix tree if needed (`ant jar`);
#   2. starts a REAL standalone ZooKeeper server from the build, root logger at DEBUG;
#   3. drives REAL client workloads through the REAL zkCli shell (org.apache.zookeeper.<MAIN>):
#        session A — bulk load: hundreds of create/set/get/ls/ls2/getAcl/delete ops
#        session B — a second, concurrent client doing the same kind of traffic
#        session C — an ordinary admin session that ends by asking for the status of a
#                    path that does not exist  <-- the failing operation
#   4. concatenates the server's own DEBUG log and the three client session logs into
#      private/symptom.orig.log (the only added text is a "===== file: X =====" collection
#      header per source file);
#   5. DETECTS the failure with a silent assertion (client C exited non-zero and its own
#      output carries an unhandled NullPointerException). The assertion result is printed
#      to reproduce.sh's stdout — it is NEVER written into the symptom log.
#
# NO print/log statement is added to ZooKeeper anywhere. The stack trace in the log is the
# JVM's own uncaught-exception report.
set -euo pipefail

REPO="${REPO:-/work/repos/Zookeeper-Zookeeper-1434}"
BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1434}"
# CLI class + status-command name. M4 renames both in the anonymized tree, so they are
# parameterised here; the defaults are the real pre-fix names.
MAIN_CLASS="${MAIN_CLASS:-org.apache.zookeeper.ZooKeeperMain}"
STAT_CMD="${STAT_CMD:-stat}"
# The shell's "missing node" message; M4 rewrites this failure-path log literal.
NONODE_MSG="${NONODE_MSG:-Node does not exist:}"
PORT="${PORT:-21811}"

RUN="$(mktemp -d /tmp/zk-repro-XXXX)"   # neutral: the JVM prints paths into the log
mkdir -p "$RUN/data" "$BUG_DIR/private" "$BUG_DIR/logs"

# ---- 1. build (idempotent) ------------------------------------------------------------
cd "$REPO"
if [ ! -d build/classes ]; then
    ant jar
fi
CP="$REPO/conf:$REPO/build/classes"
for j in "$REPO"/build/lib/*.jar; do CP="$CP:$j"; done

# ---- 2. real standalone server, root logger at DEBUG -----------------------------------
cat > "$RUN/zoo.cfg" <<CFG
tickTime=2000
initLimit=10
syncLimit=5
dataDir=$RUN/data
clientPort=$PORT
CFG

java -Dzookeeper.log.dir="$RUN" -Dzookeeper.root.logger=DEBUG,CONSOLE \
     -Dzookeeper.console.threshold=DEBUG \
     -cp "$CP" org.apache.zookeeper.server.quorum.QuorumPeerMain "$RUN/zoo.cfg" \
     > "$RUN/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; ' EXIT

for i in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/$PORT && printf 'ruok' >&3 && head -c4 <&3 | grep -q imok) 2>/dev/null; then
        break
    fi
    sleep 1
done
echo "[reproduce] server up on 127.0.0.1:$PORT (pid $SERVER_PID)"

zkcli() {  # zkcli <commands-file> <output-log>;  returns the client's exit code
    java -Dzookeeper.log.dir="$RUN" -Dzookeeper.root.logger=DEBUG,CONSOLE \
         -Dzookeeper.console.threshold=DEBUG \
         -cp "$CP" "$MAIN_CLASS" -server "127.0.0.1:$PORT" \
         < "$1" > "$2" 2>&1
}

# ---- 3a. session A — bulk real workload ------------------------------------------------
{
  echo "create /app ''"
  echo "create /app/config ''"
  echo "create /app/workers ''"
  echo "create /app/locks ''"
  for i in $(seq 1 60); do
      echo "create /app/workers/w$i host$((i%7))-payload-$i"
      echo "get /app/workers/w$i"
      echo "set /app/workers/w$i host$((i%7))-payload-$i-v2"
      echo "$STAT_CMD /app/workers/w$i"
  done
  for i in $(seq 1 20); do
      echo "create /app/config/key$i value$i"
      echo "getAcl /app/config/key$i"
  done
  echo "ls /app"
  echo "ls2 /app/workers"
  echo "ls /app/config"
  for i in $(seq 1 20); do echo "delete /app/workers/w$i"; done
  echo "ls /app/workers"
  echo "quit"
} > "$RUN/cmds_A.txt"

# ---- 3b. session B — a second concurrent client ----------------------------------------
{
  for i in $(seq 1 40); do
      echo "create /app/locks/lock-$i client-b-$i"
      echo "$STAT_CMD /app/locks/lock-$i"
      echo "get /app/locks/lock-$i"
      echo "delete /app/locks/lock-$i"
  done
  echo "ls /app/locks"
  echo "ls2 /app"
  echo "quit"
} > "$RUN/cmds_B.txt"

# ---- 3c. session C — ordinary admin session that hits the failing operation -------------
{
  echo "ls /"
  echo "ls /app"
  echo "$STAT_CMD /app"
  echo "get /app/config/key1"
  echo "$STAT_CMD /app/config/key1"
  echo "ls /app/workers"
  echo "$STAT_CMD /app/workers/w42"
  echo "$STAT_CMD /app/workers/w4242"        # <-- this znode does not exist
  echo "ls /app/config"                      #     (never reached: the shell dies above)
  echo "quit"
} > "$RUN/cmds_C.txt"

zkcli "$RUN/cmds_A.txt" "$RUN/client_A.log" || true
zkcli "$RUN/cmds_B.txt" "$RUN/client_B.log" &
B_PID=$!
zkcli "$RUN/cmds_A.txt" "$RUN/client_A2.log" || true   # concurrent traffic alongside B
wait $B_PID || true

set +e
zkcli "$RUN/cmds_C.txt" "$RUN/client_C.log"
C_RC=$?
set -e
echo "[reproduce] failing session exit code: $C_RC"

kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

# ---- 4. assemble the symptom log (system output only) ----------------------------------
OUT="$BUG_DIR/private/symptom.orig.log"
: > "$OUT"
for f in server.log client_A.log client_A2.log client_B.log client_C.log; do
    printf '===== file: %s =====\n' "$f" >> "$OUT"
    cat "$RUN/$f" >> "$OUT"
done
echo "[reproduce] wrote $OUT ($(wc -l < "$OUT") lines)"

# ---- 5. silent detection (assertion output never enters the symptom log) ---------------
FAILED=0
[ "$C_RC" -ne 0 ] || { echo "[reproduce] ASSERT FAIL: client exited 0"; FAILED=1; }
grep -q 'Exception in thread "main" java.lang.NullPointerException' "$RUN/client_C.log" \
    || { echo "[reproduce] ASSERT FAIL: no unhandled NullPointerException in client output"; FAILED=1; }
grep -qF "$NONODE_MSG" "$RUN/client_C.log" \
    && { echo "[reproduce] ASSERT FAIL: the shell handled the missing node gracefully"; FAILED=1; }

if [ "$FAILED" -eq 0 ]; then
    echo "[reproduce] REPRODUCED: the shell died with an unhandled NPE instead of reporting the missing node."
    exit 0
else
    echo "[reproduce] NOT REPRODUCED"
    exit 1
fi
