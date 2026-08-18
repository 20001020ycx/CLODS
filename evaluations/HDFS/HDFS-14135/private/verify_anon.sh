#!/usr/bin/env bash
# verify_anon.sh — METHODOLOGY §6 "Verification" for HDFS-14135.
# Every check here is expected to find NOTHING; kept in its own script because `set -e` in
# anonymize.sh would abort on grep's exit status 1 exactly when the artifacts are clean.
BUG_DIR="${BUG_DIR:-/work/evaluations/HDFS/HDFS-14135}"
PROD_LOG="${PROD_LOG:-/work/production-logs/HDFS/production.log}"
MAP="$BUG_DIR/private/anonymization_map.json"
bad=0

SMALL=("$BUG_DIR/source" "$BUG_DIR/logs/repro.log")
[ -f "$BUG_DIR/symptom.md" ] && SMALL+=("$BUG_DIR/symptom.md")
BIG="$BUG_DIR/logs/symptom.log"

report() {  # report <label> <hits-text>
    if [ -n "$2" ]; then
        echo "[verify] LEAK ($1):"; echo "$2" | head; bad=1
    else
        echo "[verify] clean: $1"
    fi
}

# ---- (a) bug-id scrub -------------------------------------------------------------------
#  * the ticket id itself must appear nowhere;
#  * the bare number must appear nowhere the reproduction controls. The merged
#    logs/symptom.log is exempt from the bare-number check only because the SHARED, read-only
#    production log carries "14135" as ordinary numeric noise (packet seqno / offsets); the
#    assertion below is the precise form — the reproduction must add zero occurrences.
report "bug id (small artifacts)" \
    "$( { grep -rF -c 'HDFS-14135' "${SMALL[@]}" 2>/dev/null || true; } | { grep -v ':0$' || true; } )"
report "bare bug number (small artifacts)" \
    "$( { grep -rE -c '\b14135\b' "${SMALL[@]}" 2>/dev/null || true; } | { grep -v ':0$' || true; } )"

if [ -f "$BIG" ]; then
    report "bug id (merged log)" "$(LC_ALL=C grep -F -m 1 'HDFS-14135' "$BIG" || true)"
    prod_hits="$(LC_ALL=C grep -cE '\b14135\b' "$PROD_LOG" || true)"
    merged_hits="$(LC_ALL=C grep -cE '\b14135\b' "$BIG" || true)"
    if [ "$prod_hits" = "$merged_hits" ]; then
        echo "[verify] clean: bare bug number in the merged log ($merged_hits hits, every one of them from the shared production log)"
    else
        echo "[verify] LEAK (bare bug number in the merged log): production=$prod_hits merged=$merged_hits"
        bad=1
    fi
fi

# ---- (b)+(c)+(d) every original identifier and rewritten literal from the map ------------
TERMS=/tmp/verify_terms.$$
python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for k in list(m["identifiers"]) + list(m["log_literals"]):
    print(k)
' "$MAP" > "$TERMS"
echo "[verify] checking $(wc -l < "$TERMS") original identifiers/literals"

report "original identifiers/literals (small artifacts)" \
    "$( { grep -rF -f "$TERMS" -c "${SMALL[@]}" 2>/dev/null || true; } | { grep -v ':0$' || true; } )"
if [ -f "$BIG" ]; then
    # one streaming pass over the GB-scale merged log, reporting which terms (if any) survive
    report "original identifiers/literals (merged log)" \
        "$(LC_ALL=C grep -F -o -f "$TERMS" "$BIG" | sort | uniq -c || true)"
fi
rm -f "$TERMS"

# ---- the anonymized names must actually be present (the rename really happened) ----------
# In source/: every renamed identifier. In the reproduction log: only the names the running
# system actually prints — the class (logger name + stack frames) and the failing check's
# method name. The helper is private, logs nothing and has returned by the time the failure
# surfaces, so it legitimately never appears in a log line.
for want in TestWebHdfsClientDeadlines fillPendingConnectQueue testDelegationTokenConnectDeadline \
            PENDING_CONNECT_CLIENTS LISTEN_QUEUE_LENGTH startOneShotRedirectResponder; do
    if LC_ALL=C grep -rqF "$want" "$BUG_DIR/source"; then
        echo "[verify] present in source/: $want"
    else
        echo "[verify] MISSING anonymized name in source/: $want"; bad=1
    fi
done
for want in TestWebHdfsClientDeadlines testListFilesConnectDeadline; do
    if LC_ALL=C grep -qF "$want" "$BUG_DIR/logs/repro.log"; then
        echo "[verify] present in repro.log: $want"
    else
        echo "[verify] MISSING anonymized name in repro.log: $want"; bad=1
    fi
done

if [ "$bad" -ne 0 ]; then
    echo "[verify] FAILED"
    exit 1
fi
echo "[verify] all clean"
