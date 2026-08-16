#!/usr/bin/env bash
# run_diagnosis.sh <BUG_DIR>  (BUG_DIR is expected mounted at /bug)
#
# Runs the LLM diagnosis 5 times. Each run is a FRESH, stateless, single-turn Claude Code
# process (claude -p), so no prior conversation/session context leaks between runs or from
# the orchestrator agent. Web tools are denied and outbound traffic is restricted to
# api.anthropic.com only (the "no internet" rule from the methodology).
#
# Clean-session guarantees (paper validity):
#   * Each run is `claude -p` with no --continue/--resume  -> brand-new process, no history.
#   * --bare   -> skips CLAUDE.md auto-discovery, auto-memory, plugins, hooks, keychain.
#   * --no-session-persistence -> the run is never saved / resumable.
#   * The agent runs inside a throwaway STAGING dir holding ONLY symptom.md, source/, and
#     logs/symptom.log. private/ (ground_truth.md, fix.diff, anonymization_map.json,
#     deps-fix.patch) is NEVER copied into staging and is therefore unreachable.
#   * Tools are restricted to read-only code inspection: Bash/Write/Edit/WebFetch/WebSearch/
#     Task/NotebookEdit are DENIED, so the agent cannot shell out, modify files, go online,
#     or spawn sub-agents that might bypass the above.
#   * Model + effort are pinned (CLODS_MODEL / CLODS_EFFORT env, default claude-opus-4-7 /
#     high) so the subject is reproducible and matches the paper's "Claude Opus 4.7,
#     thinking=high".
#
# Writes each run's full single-turn answer to <BUG_DIR>/diagnosis/run_N.md (and stderr to
# run_N.stderr). Idempotent: an existing non-empty run_N.md is skipped, so a killed agent
# can resume here. Requires the container to be started with --cap-add=NET_ADMIN so the
# iptables allowlist can be applied. See context/METHODOLOGY.md §11.

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

# Pinned subject. Override per-run via env if you need a different model/effort, but for
# the published experiment keep these fixed for reproducibility. NOTE: pin a full model
# ID, NOT the `opus` alias — the alias drifts to whatever is "latest" on run day.
MODEL="${CLODS_MODEL:-claude-opus-4-7}"   # Opus 4.7
EFFORT="${CLODS_EFFORT:-high}"

# How to invoke the CLI. Default `claude` is the container path (ANTHROPIC_API_KEY is
# passed in via -e). On a host whose Claude auth is managed by the CCS launcher (no raw
# API key exposed — `ccs env anthropic` returns no vars), set:
#   CLAUDE_CMD="ccs anthropic"  CLAUDE_PURITY_FLAG="--safe-mode"
# because `--bare` refuses CCS keychain/cliproxy auth ("Not logged in"), whereas
# --safe-mode keeps auth while still disabling CLAUDE.md/skills/plugins/hooks. Both are
# left unquoted below so a multi-word wrapper prefix (e.g. "ccs anthropic") word-splits.
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
PURITY_FLAG="${CLAUDE_PURITY_FLAG:---bare}"

# ---- Lock the network: DROP everything, then allow only the Anthropic API ---
# Best-effort: if we lack NET_ADMIN, warn but continue (the prompt + denied web tools
# still enforce the rule at the agent layer).
lock_network() {
    if ! iptables -L >/dev/null 2>&1; then
        echo "WARN: no NET_ADMIN; relying on denied web tools + prompt (no iptables lock)." >&2
        return 0
    fi
    iptables -F
    iptables -P INPUT   DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT  DROP
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    for host in api.anthropic.com statsig.anthropic.com; do
        for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
            iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
        done
    done
    echo "Network locked: egress restricted to api.anthropic.com:443." >&2
}
lock_network

# ---- Build a CLEAN staging dir: only the inputs the diagnosis LLM may see --------
# private/ is deliberately NOT copied in, so the answer key is unreachable regardless of
# how the container was mounted.
STAGE="$(mktemp -d -t clods-diag-XXXX)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/logs"
cp -a "$SOURCE_DIR"            "$STAGE/source"
cp -a "$LOG_FILE"              "$STAGE/logs/symptom.log"
cp -a "$SYMPTOM_FILE"          "$STAGE/symptom.md"

STAGE_SRC="$STAGE/source"
STAGE_LOG="$STAGE/logs/symptom.log"
SYMPTOM="$(cat "$STAGE/symptom.md")"

# ---- The single fixed prompt (methodology §5/M6) --------------------------
# Paths point into STAGE only. The agent never learns /bug or private/ exist.
read -r -d '' PROMPT <<EOF || true
Given the source code at $STAGE_SRC and the production log at $STAGE_LOG (this is a large, realistic production log - grep it for the symptom rather than reading it whole), what is the root cause of the failure: $SYMPTOM? Identify the specific lines of code and the exact logical conditions (branches) that dictate this failure path.

IMPORTANT: Do NOT connect to the internet or find other bugs with a similar symptom. Instead rely purely on your reasoning to diagnose this failure.
EOF

# ---- 5 independent, stateless runs -----------------------------------------
# Run from STAGE so the agent's workspace (and file-tool reach) is the clean dir only.
cd "$STAGE"
for n in 1 2 3 4 5; do
    out="$DIAG_DIR/run_${n}.md"
    if [ -s "$out" ]; then
        echo "run_${n}.md exists and is non-empty; skipping." >&2
        continue
    fi
    echo "=== diagnosis run $n/5 (model=$MODEL effort=$EFFORT cmd=$CLAUDE_CMD) ===" >&2
    $CLAUDE_CMD -p "$PROMPT" \
        --model "$MODEL" --effort "$EFFORT" \
        $PURITY_FLAG \
        --no-session-persistence \
        --exclude-dynamic-system-prompt-sections \
        --disallowed-tools 'Bash,Write,Edit,WebFetch,WebSearch,Task,NotebookEdit' \
        --permission-mode bypassPermissions \
        > "$out" 2> "$DIAG_DIR/run_${n}.stderr" || {
            echo "WARN: run $n exited non-zero; see run_${n}.stderr" >&2
        }
done

echo "Done. 5 diagnoses written under $DIAG_DIR" >&2