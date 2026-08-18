#!/usr/bin/env bash
# anonymize.sh — HDFS-14135, METHODOLOGY §5/M4 + §6.
#
# Runs INSIDE the per-bug container (NET_ADMIN is needed by reproduce.sh):
#   docker run --rm --cap-add=NET_ADMIN \
#       -v "$PWD:/work" -v "$PWD/repos/.m2-HDFS-HDFS-14135:/root/.m2" \
#       --entrypoint bash clods-eval:HDFS-HDFS-14135 \
#       -lc 'bash /work/evaluations/HDFS/HDFS-14135/private/anonymize.sh'
#
# 1. materialises a second checkout of the pre-fix commit (git worktree, so the M2 tree is
#    left untouched);
# 2. applies private/anonymization_map.json to the failure-path files: renames the
#    case-identifying test file + public type, its helper/constant/test-method names, and
#    rewrites the failure-path log and failure-message literals;
# 3. rebuilds and re-runs reproduce.sh against the renamed tree -> logs/repro.log (Log A);
# 4. re-applies the M3 merge against the shared read-only production log
#    -> logs/symptom.log (Log B, the only log the diagnosis LLM sees);
# 5. copies the anonymized failure-path source into source/ and commits it as a fresh local
#    git repo, so the gitignored tree is reconstructible;
# 6. verifies zero leakage of the bug id and of every original identifier/literal.
set -euo pipefail

REPO="${REPO:-/work/repos/HDFS-HDFS-14135}"
# Deliberately NOT named after the bug: the build tree's absolute path is printed into the
# reproduction log by Jetty/Hadoop (webapp resource paths), so a bug-id-bearing path would
# leak the JIRA id straight into the LLM-facing log (METHODOLOGY §6(a)).
ANON_REPO="${ANON_REPO:-/work/repos/hadoop-webhdfs-build}"
BUG_DIR="${BUG_DIR:-/work/evaluations/HDFS/HDFS-14135}"
PROD_LOG="${PROD_LOG:-/work/production-logs/HDFS/production.log}"
PRE_FIX="${PRE_FIX:-b7fba78fb63a0971835db87292822fd8cd4aa7ad}"
MAP="$BUG_DIR/private/anonymization_map.json"

TEST_DIR_REL="hadoop-hdfs-project/hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/web"
CLIENT_DIR_REL="hadoop-hdfs-project/hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/web"
COMMON_TEST_REL="hadoop-common-project/hadoop-common/src/test/java/org/apache/hadoop/test"

# containers run as root against a host-owned clone
git config --global --add safe.directory '*' || true

echo "[anonymize] 1/6 worktree at the pre-fix commit"
if [ ! -d "$ANON_REPO" ]; then
    git -C "$REPO" worktree add --detach "$ANON_REPO" "$PRE_FIX"
fi
git -C "$ANON_REPO" checkout --detach "$PRE_FIX" >/dev/null 2>&1 || true
git -C "$ANON_REPO" checkout -- . 2>/dev/null || true

echo "[anonymize] 2/6 applying the anonymization map"
git -C "$ANON_REPO" mv "$TEST_DIR_REL/TestWebHdfsTimeouts.java" \
                       "$TEST_DIR_REL/TestWebHdfsClientDeadlines.java" 2>/dev/null \
  || mv "$ANON_REPO/$TEST_DIR_REL/TestWebHdfsTimeouts.java" \
        "$ANON_REPO/$TEST_DIR_REL/TestWebHdfsClientDeadlines.java"
python3 "$BUG_DIR/private/anon_map_build.py" apply "$MAP" \
    "$ANON_REPO/$TEST_DIR_REL/TestWebHdfsClientDeadlines.java" \
    "$ANON_REPO/$CLIENT_DIR_REL/WebHdfsFileSystem.java" \
    "$ANON_REPO/$CLIENT_DIR_REL/URLConnectionFactory.java"

echo "[anonymize] 3/6 rebuild + re-reproduce from the anonymized tree"
rm -f "$ANON_REPO/cp-test.txt"
rc=0
SRC_TREE="$ANON_REPO" \
  OUT_LOG="$BUG_DIR/logs/repro.log" \
  SUITE=org.apache.hadoop.hdfs.web.TestWebHdfsClientDeadlines \
  bash "$BUG_DIR/reproduce.sh" || rc=$?
[ "$rc" -eq 0 ] || { echo "[anonymize] FATAL: the anonymized build no longer reproduces (rc=$rc)"; exit "$rc"; }

echo "[anonymize] 4/6 merging into the shared production log"
python3 "$BUG_DIR/private/merge_logs.py" \
    --production "$PROD_LOG" \
    --repro      "$BUG_DIR/logs/repro.log" \
    --out        "$BUG_DIR/logs/symptom.log" \
    --interleave position

echo "[anonymize] 5/6 source/"
rm -rf "$BUG_DIR/source"
mkdir -p "$BUG_DIR/source/hadoop-hdfs-client/src/main/java/org/apache/hadoop" \
         "$BUG_DIR/source/hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs" \
         "$BUG_DIR/source/hadoop-common/src/test/java/org/apache/hadoop"
cp -a "$ANON_REPO/hadoop-hdfs-project/hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs" \
      "$BUG_DIR/source/hadoop-hdfs-client/src/main/java/org/apache/hadoop/"
cp -a "$ANON_REPO/$TEST_DIR_REL" \
      "$BUG_DIR/source/hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/"
cp -a "$ANON_REPO/$COMMON_TEST_REL" \
      "$BUG_DIR/source/hadoop-common/src/test/java/org/apache/hadoop/"
echo "[anonymize] source/ = $(find "$BUG_DIR/source" -name '*.java' | wc -l) java files"
if [ ! -d "$BUG_DIR/source/.git" ]; then
    git -C "$BUG_DIR/source" init -q
fi
git -C "$BUG_DIR/source" add -A
git -C "$BUG_DIR/source" -c user.email=clods@local -c user.name=clods \
    commit -q -m "anonymized failure-path source" || true
git -C "$BUG_DIR/source" rev-parse HEAD

echo "[anonymize] 6/6 leakage verification"
bash "$BUG_DIR/private/verify_anon.sh"
