#!/usr/bin/env bash
# HBase-3403 — M4/M5 leakage verification (METHODOLOGY.md §6 "Verification", §5/M5 step 3).
#
#   bash evaluations/HBase/HBase-3403/private/verify_anon.sh
#
# Asserts that no original identifier of the failure path, and no form of the JIRA id,
# survives in anything the diagnosis LLM is given: source/, logs/repro.log,
# logs/symptom.log (the whole 3 GB merged log, production portion included) and symptom.md.
# Every count must be 0.  Exits non-zero on any leak.
#
# grep exits 1 when it finds nothing -- which is the success case here -- so every grep is
# guarded with `|| true` and the script must NOT use `set -e`.
set -uo pipefail

BUG_DIR=/mnt/SSD-4T/ycx/CLODS/evaluations/HBase/HBase-3403
SRC="$BUG_DIR/source"
REPRO="$BUG_DIR/logs/repro.log"
MERGED="$BUG_DIR/logs/symptom.log"
SYMPTOM="$BUG_DIR/symptom.md"

bad=0

# Original identifiers (types, methods, test names) and the JIRA id.
IDENTS=(
  'HBASE-3403' 'HBase-3403' 'hbase-3403'
  'MetaEditor' 'MetaReader' 'ServerShutdownHandler' 'MetaServerShutdownHandler'
  'offlineParentInMeta' 'fixupDaughters' 'fixupDaughter' 'addDaughter'
  'getServerUserRegions' 'processDeadRegion'
  'TestSplitCrashRecovery' 'testDaughterAfterServerCrash' 'TestMetaReaderEditor'
)
# Original log literals on the failure path (the first two are quoted by the JIRA report).
LITERALS=(
  'on HDFS, but not listed in META'
  'Found inconsistency in table'
  'is inconsistent.'
  'inconsistencies detected'
  'Status: INCONSISTENT'
  'Offlined parent region'
  'Added daughter'
  'Deleted daughter reference'
  'Splitting logs for'
  'regions(s) that are already in transition'
  'Finished processing of shutdown of'
  'Offlined and split region'
  'checking daughter presence'
  'Fixup; missing daughter'
  'offline, split, parent, ignoring'
)

count_in() {   # count_in <pattern> <path...>   (word-boundary fixed-string, recursive)
  local pat="$1"; shift
  grep -rowF -- "$pat" "$@" 2>/dev/null | wc -l
}

echo "== source/ + logs/repro.log + symptom.md =="
TARGETS=("$SRC" "$REPRO")
SYMPTOM_OPT=""
[ -f "$SYMPTOM" ] && { TARGETS+=("$SYMPTOM"); SYMPTOM_OPT="$SYMPTOM"; }
for pat in "${IDENTS[@]}" "${LITERALS[@]}"; do
  n=$(count_in "$pat" "${TARGETS[@]}")
  printf '  %-42s %s\n' "$pat" "$n"
  [ "$n" -eq 0 ] || bad=1
done

# NOTE on the pre-fix "Reassigning N region(s) that S was carrying ..." literal: its
# distinctive tail, "regions(s) that are already in transition", is checked above and must be
# absent everywhere.  The generic head ("Reassigning", "was carrying") is NOT checked, because
# HBase 1.2.7's ServerCrashProcedure -- the modern descendant of ServerShutdownHandler --
# legitimately logs "Reassigning 0 region(s) that <server> was carrying (and 0 regions(s) that
# were opening on this server)" 15 times in the shared production log.  That is production
# noise, not reproduction leakage, and the production log is never modified.
PRODUCTION_OWN=()
in_production_own() { local x; for x in "${PRODUCTION_OWN[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

echo "== logs/symptom.log (whole merged 3 GB log, production portion included) =="
for pat in "${IDENTS[@]}" "${LITERALS[@]}"; do
  if in_production_own "$pat"; then
    printf '  %-42s %s\n' "$pat" "skipped (HBase 1.2.7 ServerCrashProcedure noise)"
    continue
  fi
  n=$(grep -owF -- "$pat" "$MERGED" 2>/dev/null | wc -l)
  printf '  %-42s %s\n' "$pat" "$n"
  [ "$n" -eq 0 ] || bad=1
done

# The bare token 3403 must be absent from everything WE produce.  In the production portion
# of the merged log it occurs 183 times as genuine HBase/Hadoop/ZooKeeper RPC sequence
# numbers ("... from root sending #3403", "header:: 3403,8") -- coincidental digits in real
# production noise, produced long before this bug was chosen, and the shared production log is
# read-only (METHODOLOGY §13).  Those are therefore not rewritten; what IS asserted is that no
# occurrence anywhere is part of a ticket-shaped token (hbase/jira/issue/bug + 3403).
echo "== bare token 3403 =="
for tgt in "$SRC" "$REPRO" ${SYMPTOM_OPT:-}; do
  n=$(grep -rowF -- '3403' "$tgt" 2>/dev/null | wc -l)
  printf '  %-42s %s (must be 0)\n' "$(basename "$tgt")" "$n"
  [ "$n" -eq 0 ] || bad=1
done
n=$(grep -owF -- '3403' "$MERGED" 2>/dev/null | wc -l)
printf '  %-42s %s (production RPC/ZK sequence numbers, kept verbatim)\n' "symptom.log" "$n"
n=$(grep -oiE -- '(hbase|jira|issue|bug)[^0-9a-z]{0,3}3403' "$MERGED" 2>/dev/null | wc -l)
printf '  %-42s %s (must be 0)\n' "ticket-shaped 3403 in symptom.log" "$n"
[ "$n" -eq 0 ] || bad=1

echo "== case-insensitive bug-id sweep (paths, comments, anything) =="
for tgt in "$SRC" "$REPRO" "$MERGED" ${SYMPTOM_OPT:-}; do
  n=$(grep -riolF -- 'hbase-3403' "$tgt" 2>/dev/null | wc -l)
  printf '  %-42s %s\n' "$(basename "$tgt")" "$n"
  [ "$n" -eq 0 ] || bad=1
done

echo "== positive controls (the anonymized forms MUST be present) =="
for pair in \
  "CatalogWriter:$SRC" "CatalogScanner:$SRC" "LostServerHandler:$SRC" \
  "offlineSplitParent:$SRC" "recoverSplitChildren:$SRC" \
  "has a directory on HDFS with no catalog row:$REPRO" \
  "Consistency check failed for table:$REPRO" \
  "Took split parent:$REPRO" \
  "has a directory on HDFS with no catalog row:$MERGED" ; do
  pat="${pair%%:*}"; tgt="${pair##*:}"
  n=$(grep -rowF -- "$pat" "$tgt" 2>/dev/null | wc -l)
  printf '  %-46s %-14s %s\n' "$pat" "$(basename "$tgt")" "$n"
  [ "$n" -gt 0 ] || bad=1
done

echo
echo "source/          : $(find "$SRC" -name '*.java' 2>/dev/null | wc -l) java files"
echo "logs/repro.log   : $(wc -l < "$REPRO") lines"
echo "logs/symptom.log : $(wc -l < "$MERGED") lines, $(du -h "$MERGED" | cut -f1)"
if [ "$bad" -eq 0 ]; then echo "VERIFY OK: no original identifier or literal leaked"; exit 0
else echo "VERIFY FAILED"; exit 1; fi
