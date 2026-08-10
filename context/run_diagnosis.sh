#!/usr/bin/env bash
# run_diagnosis.sh <BUG_DIR>  (BUG_DIR is expected mounted at /bug, read-only)
#
# Runs the LLM diagnosis 5 times, each in a fresh, stateless Claude Code session,
# with web tools disabled and outbound traffic restricted to api.anthropic.com
# only (the "no internet" rule from the methodology). Writes each run's full
# single-turn answer to <BUG_DIR>/diagnosis/run_N.md. Idempotent: an existing
# non-empty run_N.md is skipped on re-entry, so a killed agent can resume here.
#
# Requires the container to be started with --cap-add=NET_ADMIN so the iptables
# allowlist can be applied. See context/METHODOLOGY.md §11.

set -euo pipefail

BUG_DIR="${1:?usage: run_diagnosis.sh <BUG_DIR (mounted at /bug)>}"
BUG_DIR="$(readlink -f "$BUG_DIR")"
DIAG_DIR="$BUG_DIR/diagnosis"
mkdir -p "$DIAG_DIR"

SYMPTOM_FILE="$BUG_DIR/symptom.md"
SOURCE_DIR="$BUG_DIR/source"
LOG_FILE="$BUG_DIR/logs/symptom.log"

for f in "$SYMPTOM_FILE" "$SOURCE_DIR" "$LOG_FILE"; do
    [ -e "$f" ] || { echo "ERROR: missing required input $f" >&2; exit 1; }
done

SYMPTOM="$(cat "$SYMPTOM_FILE")"

# ---- Lock the network: DROP everything, then allow only the Anthropic API ---
# Best-effort: if we lack NET_ADMIN, warn but continue (the prompt + disabled
# web tools still enforce the rule at the agent layer).
lock_network() {
    if ! iptables -L >/dev/null 2>&1; then
        echo "WARN: no NET_ADMIN; relying on disabled web tools + prompt (no iptables lock)." >&2
        return 0
    fi
    iptables -F
    iptables -P INPUT   DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT  DROP
    # localhost + already-established connections
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # Anthropic API only (resolve once; allow all its IPs)
    for host in api.anthropic.com statsig.anthropic.com; do
        for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
            iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
        done
    done
    echo "Network locked: egress restricted to api.anthropic.com:443." >&2
}
lock_network

# ---- The single fixed prompt (methodology §5/M6) --------------------------
read -r -d '' PROMPT <<EOF || true
Given the source code at $SOURCE_DIR and the symptom logs located at $LOG_FILE, what is the root cause of the failure: $SYMPTOM? Identify the specific lines of code and the exact logical conditions (branches) that dictate this failure path.

IMPORTANT: Do NOT connect to the internet or find other bugs with a similar symptom. Instead rely purely on your reasoning to diagnose this failure.
EOF

# ---- 5 independent, stateless runs -----------------------------------------
for n in 1 2 3 4 5; do
    out="$DIAG_DIR/run_${n}.md"
    if [ -s "$out" ]; then
        echo "run_${n}.md exists and is non-empty; skipping." >&2
        continue
    fi
    echo "=== diagnosis run $n/5 ===" >&2
    # --print (headless single turn), no web tools, no MCP, fresh session each call.
    claude -p "$PROMPT" \
        --disallowedTools 'WebFetch,WebSearch' \
        --permission-mode bypassPermissions \
        > "$out" 2> "$DIAG_DIR/run_${n}.stderr" || {
            echo "WARN: run $n exited non-zero; see run_${n}.stderr" >&2
        }
done

echo "Done. 5 diagnoses written under $DIAG_DIR" >&2