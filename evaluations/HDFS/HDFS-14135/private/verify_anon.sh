#!/usr/bin/env bash
# verify_anon.sh — METHODOLOGY §6 "Verification" for HDFS-14135.
# Every grep here is expected to find NOTHING; kept in its own script because `set -e` in
# anonymize.sh would abort on grep's exit status 1 exactly when the artifacts are clean.
BUG_DIR="${BUG_DIR:-/work/evaluations/HDFS/HDFS-14135}"
bad=0

check() {  # check <label> <grep-args...>
    local label="$1"; shift
    local hits
    hits="$( { grep -rEc "$@" 2>/dev/null || true; } | { grep -v ':0$' || true; } )"
    if [ -n "$hits" ]; then
        echo "[verify] LEAK ($label):"; echo "$hits" | head; bad=1
    else
        echo "[verify] clean: $label"
    fi
}

TARGETS=("$BUG_DIR/source" "$BUG_DIR/logs/repro.log" "$BUG_DIR/logs/symptom.log")
[ -f "$BUG_DIR/symptom.md" ] && TARGETS+=("$BUG_DIR/symptom.md")

# (a) bug-id scrub
check "bug id" 'HDFS-14135|\b14135\b' "${TARGETS[@]}"

# (b)+(c)+(d) every original identifier and rewritten literal from the map
while IFS= read -r term; do
    check "$term" -- "$term" "${TARGETS[@]}"
done < <(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for k in list(m["identifiers"]) + list(m["log_literals"]):
    print(k)
' "$BUG_DIR/private/anonymization_map.json")

if [ "$bad" -ne 0 ]; then
    echo "[verify] FAILED"
    exit 1
fi
echo "[verify] all clean"
