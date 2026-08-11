#!/usr/bin/env bash
# anonymize.sh — Zookeeper-1434, M4.
#
# Deterministically regenerates the two gitignored, LLM-facing artifacts:
#   <BUG_DIR>/source/        curated real failure-path sources, with the renames applied
#   <BUG_DIR>/logs/symptom.log   the real DEBUG reproduction log of the RENAMED build
#
# Anonymization is minimal and case-targeted (METHODOLOGY §6):
#   (a) bug-id scrub    — neither JIRA id (the report's own, nor the trunk ticket that
#                         carries the fix) nor its bare number may appear anywhere;
#   (b) distinctive-term rename — the two identifiers that *name* the case and that the
#                         JIRA-quoted stack trace string-matches on:
#                             the CLI command  "stat"   -> "meta"
#                             the printer      printStat -> printNodeMeta
#   (c) JIRA-quoted-text redaction — the ticket quotes a stack trace; after (b) the trace
#                         this build produces no longer matches it (different method name,
#                         different command, different line numbers).
# Everything else stays real: package names, ZooKeeperMain/ZooKeeper/ClientCnxn/
# KeeperException class names, the Stat data class, the server-side log, all identifiers.
#
# The log is NOT rewritten after the fact: the anonymized tree is REBUILT and reproduce.sh
# is re-run against it, so the log is the genuine output of the renamed binary. The tree is
# built at a neutral path (repos/zookeeper-anonymized) because the JVM prints its classpath
# and user.dir into the log.
#
# Run inside the per-bug container:
#   docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1434 \
#       -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1434/private/anonymize.sh'
set -euo pipefail

BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1434}"
REPO="${REPO:-/work/repos/Zookeeper-Zookeeper-1434}"          # pre-fix build tree (M2)
ANON_REPO="${ANON_REPO:-/work/repos/zookeeper-anonymized}"    # neutral path, no bug id

# ---- 1. copy the pre-fix working tree (incl. deps-fix) to the neutral path -------------
rm -rf "$ANON_REPO"
mkdir -p "$ANON_REPO"
tar -C "$REPO" --exclude=.git --exclude=build -cf - . | tar -C "$ANON_REPO" -xf -

# ---- 2. apply the renames --------------------------------------------------------------
MAIN_JAVA="$ANON_REPO/src/java/main/org/apache/zookeeper/ZooKeeperMain.java"
sed -i \
    -e 's/\bprintStat\b/printNodeMeta/g' \
    -e 's/commandMap\.put("stat"/commandMap.put("meta"/' \
    -e 's/cmd\.equals("stat")/cmd.equals("meta")/' \
    "$MAIN_JAVA"
grep -q 'printStat' "$MAIN_JAVA" && { echo "rename failed: printStat still present" >&2; exit 1; }
grep -q '"stat"'    "$MAIN_JAVA" && { echo "rename failed: \"stat\" still present" >&2; exit 1; }

# ---- 3. rebuild the renamed tree --------------------------------------------------------
( cd "$ANON_REPO" && ant jar )

# ---- 4. re-run the reproduction against the renamed build -------------------------------
REPO="$ANON_REPO" BUG_DIR="$BUG_DIR" STAT_CMD=meta PORT="${PORT:-21812}" \
    bash "$BUG_DIR/reproduce.sh"

# ---- 5. publish the log -----------------------------------------------------------------
mkdir -p "$BUG_DIR/logs"
cp "$BUG_DIR/private/symptom.orig.log" "$BUG_DIR/logs/symptom.log"

# ---- 6. publish the curated failure-path sources ----------------------------------------
SRC="$BUG_DIR/source"
rm -rf "$SRC"; mkdir -p "$SRC"
FILES="
src/java/main/org/apache/zookeeper/ZooKeeperMain.java
src/java/main/org/apache/zookeeper/ZooKeeper.java
src/java/main/org/apache/zookeeper/ClientCnxn.java
src/java/main/org/apache/zookeeper/KeeperException.java
src/java/main/org/apache/zookeeper/JLineZNodeCompletor.java
src/java/main/org/apache/zookeeper/ZooDefs.java
src/java/main/org/apache/zookeeper/Watcher.java
src/java/main/org/apache/zookeeper/Quotas.java
src/java/main/org/apache/zookeeper/StatsTrack.java
src/java/main/org/apache/zookeeper/AsyncCallback.java
src/java/generated/org/apache/zookeeper/data/Stat.java
src/java/generated/org/apache/zookeeper/data/ACL.java
src/java/generated/org/apache/zookeeper/data/Id.java
src/java/generated/org/apache/zookeeper/proto/ExistsRequest.java
src/java/generated/org/apache/zookeeper/proto/SetDataRequest.java
src/java/generated/org/apache/zookeeper/proto/ReplyHeader.java
"
for f in $FILES; do
    mkdir -p "$SRC/$(dirname "$f")"
    cp "$ANON_REPO/$f" "$SRC/$f"
done

# ---- 7. verification (METHODOLOGY §6) ---------------------------------------------------
rc=0
if grep -RniE 'ZOOKEEPER-(1434|1059)|\b1434\b|\b1059\b' "$SRC" "$BUG_DIR/logs/symptom.log" "$BUG_DIR/symptom.md" 2>/dev/null; then
    echo "LEAK: bug id present" >&2; rc=1
fi
if grep -RnwF 'printStat' "$SRC" "$BUG_DIR/logs/symptom.log" 2>/dev/null; then
    echo "LEAK: printStat present" >&2; rc=1
fi
if grep -RnE '(^|[^a-zA-Z])stat (/|\[)' "$BUG_DIR/logs/symptom.log" 2>/dev/null | head -5; then
    echo "LEAK: the original command name appears in the log" >&2; rc=1
fi
[ $rc -eq 0 ] && echo "[anonymize] OK: source/ and logs/symptom.log regenerated, no leakage."
exit $rc
