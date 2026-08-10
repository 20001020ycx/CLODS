#!/usr/bin/env bash
# anonymize.sh — deterministically (re)generate the LLM-facing artifacts for
# HDFS-11896 under the minimal, case-targeted anonymization policy (METHODOLOGY §6):
#   * KEEP the real HDFS source and identifiers (datanode/namenode/block/class names).
#   * SCRUB the JIRA bug id everywhere (HDFS-11896 / bare 11896).
#   * RENAME only the distinctive metric term  nonDfsUsed -> otherUsed  (+ variants).
#
# Produces (both gitignored, rebuilt on resume):
#   source/            = the real failure-path .java files, metric renamed, id scrubbed
#   logs/symptom.log   = the real M3 reproduction log, metric renamed, id scrubbed
#
# Inputs: the pre-fix scratch tree (repos/HDFS-HDFS-11896 @ b51623503fb) and the real
# reproduction log private/symptom.orig.log (regenerate via reproduce.sh if missing).
set -euo pipefail

BUG="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$BUG/../../.." && pwd)"              # repo root
REPO="${REPO:-$ROOT/repos/HDFS-HDFS-11896}"
J="$REPO/hadoop-hdfs-project/hadoop-hdfs/src/main/java"

# Real failure-path files given to the LLM (paths relative to the java source root).
FILES=(
  org/apache/hadoop/hdfs/server/blockmanagement/DatanodeDescriptor.java
  org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java
  org/apache/hadoop/hdfs/server/blockmanagement/DatanodeManager.java
  org/apache/hadoop/hdfs/server/blockmanagement/BlockManager.java
  org/apache/hadoop/hdfs/server/blockmanagement/DatanodeStorageInfo.java
  org/apache/hadoop/hdfs/server/blockmanagement/DatanodeStatistics.java
  org/apache/hadoop/hdfs/protocol/DatanodeInfo.java
  org/apache/hadoop/hdfs/server/protocol/StorageReport.java
  org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java
)

# The single anonymization transform: metric rename + bug-id scrub.
anon() {
  sed -E \
    -e 's/nonDFS/other/g' -e 's/NonDFS/Other/g' \
    -e 's/nonDfs/other/g' -e 's/NonDfs/Other/g' \
    -e 's/[Nn]on-DFS/other/g' -e 's/non-dfs/other/g' \
    -e 's/[Nn]on[ -]?[Dd][Ff][Ss]/other/g' \
    -e 's#HDFS-HDFS-11896#hdfs-eval#g' -e 's#HDFS-11896#hdfs-eval#g' \
    -e 's/\b11896\b/xxxxx/g'
}

echo "[anonymize] building source/ from real failure-path files ..."
rm -rf "$BUG/source" && mkdir -p "$BUG/source"
for f in "${FILES[@]}"; do
  mkdir -p "$BUG/source/$(dirname "$f")"
  anon < "$J/$f" > "$BUG/source/$f"
done

echo "[anonymize] building logs/symptom.log from the real reproduction log ..."
mkdir -p "$BUG/logs"
anon < "$BUG/private/symptom.orig.log" > "$BUG/logs/symptom.log"

echo "[anonymize] verification ..."
fail=0
if grep -RnE 'HDFS-11896|\b11896\b' "$BUG/source" "$BUG/logs/symptom.log" "$BUG/symptom.md" 2>/dev/null; then
  echo "  !! bug id leaked"; fail=1; fi
if grep -RnwE 'nonDfsUsed|NonDfsUsed|nonDFSUsed|NonDFSUsed|getNonDfsUsed|setNonDfsUsed|capacityUsedNonDfs|getNonDfsUsedSpace|getCapacityUsedNonDFS' \
     "$BUG/source" "$BUG/logs/symptom.log" 2>/dev/null; then
  echo "  !! distinctive term leaked"; fail=1; fi
[ "$fail" = 0 ] && echo "  CLEAN: no bug id, no nonDfs* term in source/ or symptom.log"
exit $fail
