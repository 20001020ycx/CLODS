#!/usr/bin/env bash
# Anonymize the REAL production NameNode log with the SAME technique as private/anonymize.sh:
#   * scrub JIRA bug id (HDFS-11896 / bare 11896)  [none present here, run anyway]
#   * rename the distinctive metric term nonDfs -> other (CapacityUsedNonDFS -> CapacityUsedOther,
#     getCapacityUsedNonDFS -> getCapacityUsedOther, "non DFS" -> "other")
# Everything else (class names, IPs, UUIDs, cluster id) is kept, per the minimal policy.
set -euo pipefail
SRC="${1:?master log path}"; OUT="${2:?output path}"
sed -E \
  -e 's/nonDFS/other/g' -e 's/NonDFS/Other/g' \
  -e 's/nonDfs/other/g' -e 's/NonDfs/Other/g' \
  -e 's/[Nn]on-DFS/other/g' -e 's/non-dfs/other/g' \
  -e 's/[Nn]on[ -]?[Dd][Ff][Ss]/other/g' \
  -e 's#HDFS-HDFS-11896#hdfs-eval#g' -e 's#HDFS-11896#hdfs-eval#g' \
  -e 's/\b11896\b/xxxxx/g' \
  < "$SRC" > "$OUT"
