#!/usr/bin/env bash
# reproduce.sh — HDFS-14135
#
# Symptom: a WebHDFS client run that is supposed to hit a *connect* timeout against an
# unreachable NameNode HTTP endpoint instead connects successfully and only fails later with
# a *read* timeout, so the run reports a failed expectation.
#
# Runs INSIDE the per-bug container (NET_ADMIN is required — see step 2):
#   docker run --rm --cap-add=NET_ADMIN \
#       -v "$PWD:/work" -v "$PWD/repos/.m2-HDFS-HDFS-14135:/root/.m2" \
#       --entrypoint bash clods-eval:HDFS-HDFS-14135 \
#       -lc 'bash /work/evaluations/HDFS/HDFS-14135/reproduce.sh'
#
# What it does — all of it real system activity, nothing injected into the logs:
#   1. builds the pre-fix tree if needed (mvn package) and compiles the traffic driver;
#   2. adds a small (2 ms) latency to the loopback device, the way a loaded CI/production
#      host behaves. This does not change a single line of the system under test; it only
#      makes the pre-existing race lose often enough to observe. See reproduce.md.
#   3. drives REAL WebHDFS traffic (create / write / read / checksum / rename / list /
#      delete) through the real REST client against a REAL MiniDFSCluster (NameNode +
#      3 DataNodes), root logger at DEBUG;
#   4. runs the real WebHDFS socket-deadline suite three times, the way CI re-runs a job,
#      each with the root logger at DEBUG;
#   5. concatenates the session logs into private/symptom.orig.log (the only added text is
#      the "===== host__path =====" collection header used by the shared production log);
#   6. DETECTS the failure with a silent assertion over the collected log. Assertion output
#      goes to reproduce.sh's stdout — it is NEVER written into the symptom log.
#
# NO print/log statement is added to Hadoop anywhere. Workload.java writes nothing to
# stdout/stderr: its observations go to a result file that is not part of the symptom log.
set -euo pipefail

REPO="${REPO:-/work/repos/HDFS-HDFS-14135}"
BUG_DIR="${BUG_DIR:-/work/evaluations/HDFS/HDFS-14135}"
SRC_TREE="${SRC_TREE:-$REPO}"            # M4 points this at the anonymized rebuild
OUT_LOG="${OUT_LOG:-$BUG_DIR/private/symptom.orig.log}"
SUITE="${SUITE:-org.apache.hadoop.hdfs.web.TestWebHdfsTimeouts}"
SUITE_RUNS="${SUITE_RUNS:-3}"
LOOPBACK_DELAY="${LOOPBACK_DELAY:-2ms}"

RUN="$(mktemp -d /tmp/hdfs-repro-XXXX)"
mkdir -p "$BUG_DIR/private" "$BUG_DIR/logs"
HDFS_MOD="$SRC_TREE/hadoop-hdfs-project/hadoop-hdfs"

# ---- 1. build (idempotent) -------------------------------------------------------------
cd "$SRC_TREE"
if [ ! -f "$HDFS_MOD/target/hadoop-hdfs-3.3.0-SNAPSHOT-tests.jar" ]; then
    mvn -pl hadoop-hdfs-project/hadoop-hdfs -am package \
        -DskipTests -DskipITs -Dcheckstyle.skip -Drat.skip -Dmaven.javadoc.skip=true
fi
if [ ! -f "$SRC_TREE/cp-test.txt" ]; then
    (cd "$HDFS_MOD" && mvn org.apache.maven.plugins:maven-dependency-plugin:3.1.1:build-classpath \
        -Dmdep.outputFile="$SRC_TREE/cp-test.txt" -DincludeScope=test -q)
fi
# The client classes come first: the sibling jars in ~/.m2 are the *unmodified* install
# from M2, so the tree being exercised must win over them (this matters at M4, where the
# hdfs-client sources carry the rewritten failure-path log literals).
CP="$HDFS_MOD/target/test-classes:$HDFS_MOD/target/classes"
CP="$CP:$SRC_TREE/hadoop-hdfs-project/hadoop-hdfs-client/target/classes"
CP="$CP:$(cat "$SRC_TREE/cp-test.txt")"

mkdir -p "$RUN/wl"
javac -nowarn -cp "$CP" -d "$RUN/wl" "$BUG_DIR/private/repro/Workload.java" 2>"$RUN/javac.log"

JVM_OPTS=(-Dlog4j.configuration="file:$BUG_DIR/private/repro/log4j-repro.properties"
          -Dhadoop.log.dir="$RUN" -Dtest.build.data="$RUN/tbd")

# ---- 2. loaded-host network timing -----------------------------------------------------
if ! tc qdisc replace dev lo root netem delay "$LOOPBACK_DELAY" 2>"$RUN/tc.log"; then
    echo "[reproduce] ASSERT FAIL: cannot shape the loopback device — run the container with --cap-add=NET_ADMIN"
    cat "$RUN/tc.log"
    exit 1
fi
echo "[reproduce] loopback delay set to $LOOPBACK_DELAY"

# ---- 3. real WebHDFS traffic against a real mini cluster --------------------------------
run_workload() {  # run_workload <name> <files>
    java "${JVM_OPTS[@]}" -cp "$RUN/wl:$CP" Workload "$RUN/result_$1.txt" "$2" \
        > "$RUN/client_$1.log" 2>&1 || true
}
run_workload a 3

# ---- 4. the real socket-deadline suite, re-run the way CI re-runs a job ------------------
SUITE_FAILED=0
for i in $(seq 1 "$SUITE_RUNS"); do
    set +e
    java "${JVM_OPTS[@]}" -cp "$CP" org.junit.runner.JUnitCore "$SUITE" \
        > "$RUN/suite_$i.log" 2>&1
    rc=$?
    set -e
    echo "[reproduce] suite run $i exit=$rc  $(grep -m1 -E '^OK \(|^Tests run:' "$RUN/suite_$i.log" || true)"
    [ "$rc" -ne 0 ] && SUITE_FAILED=$((SUITE_FAILED + 1))
done

# ---- 5. more ordinary traffic, then assemble the log ------------------------------------
run_workload b 2

tc qdisc del dev lo root 2>/dev/null || true

OUT="$OUT_LOG"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
emit() {  # emit <file> <collection-header>
    [ -f "$RUN/$1" ] || return 0
    printf '===== %s =====\n' "$2" >> "$OUT"
    cat "$RUN/$1" >> "$OUT"
}
emit client_a.log hadoop-client7__opt_hadoop_logs__hadoop.log
emit suite_1.log  hadoop-client7__opt_hadoop_logs__hadoop.log.1
emit suite_2.log  hadoop-client7__opt_hadoop_logs__hadoop.log.2
emit suite_3.log  hadoop-client7__opt_hadoop_logs__hadoop.log.3
emit client_b.log hadoop-client8__opt_hadoop_logs__hadoop.log
echo "[reproduce] wrote $OUT ($(wc -l < "$OUT") lines)"
cp -a "$RUN"/result_*.txt "$BUG_DIR/private/" 2>/dev/null || true

# ---- 6. silent detection (assertion output never enters the symptom log) -----------------
FAILED=0
[ "$SUITE_FAILED" -gt 0 ] \
    || { echo "[reproduce] ASSERT FAIL: every suite run passed"; FAILED=1; }
grep -qE "Expected to find '.*: connect timed out' but got unexpected exception: java.net.SocketTimeoutException: .*: Read timed out" "$OUT" \
    || { echo "[reproduce] ASSERT FAIL: no run reported a read timeout where a connect timeout was expected"; FAILED=1; }
grep -q '^written=3' "$BUG_DIR/private/result_a.txt" \
    || { echo "[reproduce] ASSERT FAIL: ordinary WebHDFS traffic did not complete"; FAILED=1; }

echo "[reproduce] --- ordinary traffic result ---"; sed 's/^/[reproduce]   /' "$BUG_DIR/private/result_a.txt"
echo "[reproduce] --- observed expectation failures ---"
grep -hE "^java.lang.AssertionError" "$OUT" | sed 's/^/[reproduce]   /' | sort -u

if [ "$FAILED" -eq 0 ]; then
    echo "[reproduce] REPRODUCED: a connection that was expected to time out was established instead,"
    echo "[reproduce]             and the run failed later on a read deadline."
    exit 0
else
    echo "[reproduce] NOT REPRODUCED"
    exit 1
fi
