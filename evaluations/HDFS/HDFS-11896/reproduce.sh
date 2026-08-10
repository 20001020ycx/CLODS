#!/usr/bin/env bash
# reproduce.sh — HDFS-11896 "Non-dfsUsed doubled on dead node re-registration"
#
# Reproduces the failure on the branch-2.7 pre-fix tree via a MiniDFSCluster
# unit driver (a full real cluster run is impractical; the minicluster exercises
# the exact NameNode block-management failure path). Writes the symptom log to
# evaluations/HDFS/HDFS-11896/logs/symptom.log.
#
# Run from the repo root INSIDE the per-bug image, repo mounted at /work:
#   docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:HDFS-HDFS-11896 \
#       -lc 'bash /work/evaluations/HDFS/HDFS-11896/reproduce.sh'
#
# Prerequisites (M2): scratch clone checked out at pre_fix_commit
#   b51623503fbd71b88647c175a79470d19b11d907 (branch-2.7, 2.7.4-SNAPSHOT), built
#   with Temurin JDK8 + protobuf 2.5.0 (see private/Dockerfile.hdfs11896).
set -euo pipefail

WORK="${WORK:-/work}"
REPO="$WORK/repos/HDFS-HDFS-11896"
M2="$WORK/repos/.m2-HDFS-11896-27"
BUG="$WORK/evaluations/HDFS/HDFS-11896"
HDFS="hadoop-hdfs-project/hadoop-hdfs"

cd "$REPO"

# 1. Ensure the reproduction harness is present (test-only; no production edits):
#    - SimulatedFSDataset reports a nonzero, deterministic non-DFS-used value so
#      the doubled metric is observable (upstream hardcodes 0L, making it vacuous).
#    - TestReReg11896 drives stop -> dead -> re-register and prints the metric.
if ! grep -q "getCapacity() / 4" "$HDFS/src/test/java/org/apache/hadoop/hdfs/server/datanode/SimulatedFSDataset.java"; then
  git apply "$BUG/private/repro/SimulatedFSDataset.nonDfs.patch"
fi
cp "$BUG/private/repro/TestReReg11896.java" \
   "$HDFS/src/test/java/org/apache/hadoop/hdfs/server/namenode/TestReReg11896.java"

# 2. Clean build of hadoop-hdfs + deps (clean avoids stale cross-branch classes).
find . -type d -name target -prune -exec rm -rf {} + 2>/dev/null || true
mvn -B -q -Dmaven.repo.local="$M2" -pl "$HDFS" -am \
    install -DskipTests -Dmaven.javadoc.skip=true -Dmaven.source.skip=true

# 3. Run the reproduction test; tee full output.
RAW="$(mktemp)"
set +e
mvn -B -o -Dmaven.repo.local="$M2" -pl "$HDFS" \
    test -Dtest=TestReReg11896 -DfailIfNoTests=false \
    -Dsurefire.useFile=false -Dmaven.test.redirectTestOutputToFile=false > "$RAW" 2>&1
set -e

# 4. Extract the symptom log = HDFS runtime logs + our probe/symptom markers.
mkdir -p "$BUG/logs"
grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} |^PROBE |^SYMPTOM|^REPRO_RESULT|AssertionError' \
    "$RAW" > "$BUG/logs/symptom.log"

echo "---- symptom summary ----"
grep -E '^PROBE|^SYMPTOM|^REPRO_RESULT' "$BUG/logs/symptom.log" || true
grep -q "REPRO_RESULT=BUG_REPRODUCED" "$BUG/logs/symptom.log" \
  && echo "reproduce.sh: BUG REPRODUCED" \
  || { echo "reproduce.sh: FAILED TO REPRODUCE" >&2; exit 2; }
