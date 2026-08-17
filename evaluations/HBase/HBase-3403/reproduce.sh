#!/usr/bin/env bash
# HBase-3403 reproduction driver.
#
# Runs INSIDE the clods-eval:HBase-HBase-3403 container (JDK 8) with the CLODS repo
# mounted at /work.  Builds the pre-fix HBase tree from source and runs the
# reproduction test, capturing the system's own DEBUG log.
#
#   docker run --rm -v "$PWD:/work" --entrypoint bash \
#     clods-eval:HBase-HBase-3403 /work/evaluations/HBase/HBase-3403/reproduce.sh
#
# Output log: $OUT_LOG (default private/symptom.orig.log at M3, logs/repro.log at M4).
set -euo pipefail

BUG_DIR=/work/evaluations/HBase/HBase-3403
SRC=${SRC:-/work/repos/HBase-HBase-3403}          # M3: pre-fix tree; M4: anonymized tree
OUT_LOG=${OUT_LOG:-$BUG_DIR/private/symptom.orig.log}
SETTINGS=${SETTINGS:-/work/repos/m2-HBase-3403/settings.xml}
TEST=${TEST:-TestSplitCrashRecovery}

export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
export MAVEN_OPTS="-Xmx3g"

mkdir -p "$(dirname "$OUT_LOG")"

echo "== build (pre-fix tree at $SRC) =="
cd "$SRC"
mvn -B -q -s "$SETTINGS" -DskipTests test-compile

echo "== reproduce: $TEST =="
# Surefire writes the test's own DEBUG output (log4j -> stdout) to
# target/surefire-reports/<class>-output.txt because redirectTestOutputToFile=true.
rm -rf target/surefire-reports
set +e
mvn -B -s "$SETTINGS" -Dtest="$TEST" -DfailIfNoTests=false test
MVN_RC=$?
set -e

# The system's own log output is the reproduction log.  No line of it is injected by
# us: it is log4j output of HBase/Hadoop at DEBUG.
cp "target/surefire-reports/org.apache.hadoop.hbase.util.${TEST}-output.txt" "$OUT_LOG"

echo "== reproduction log: $OUT_LOG ($(wc -l < "$OUT_LOG") lines) =="
echo "== surefire verdict =="
sed -n '1,40p' "target/surefire-reports/org.apache.hadoop.hbase.util.${TEST}.txt" || true
exit $MVN_RC
