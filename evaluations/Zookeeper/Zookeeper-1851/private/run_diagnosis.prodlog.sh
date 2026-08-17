#!/usr/bin/env bash
# run_diagnosis.sh <BUG_DIR>  (BUG_DIR is expected mounted at /bug)
#
# Runs the LLM diagnosis 5 times. Each run is a FRESH, stateless, single-turn Claude Code
# process (claude -p), so no prior conversation/session context leaks between runs or from
# the orchestrator agent. Web tools are denied and outbound traffic is restricted to the
# model gateway only (the yscope-anthropic-paper-validation endpoint, https://llm-gateway.yscope.io) — the
# "no internet" rule from the methodology. The subject is Claude Opus 4.7 reached through
# the `ccs yscope-anthropic-paper-validation` profile (the org's Anthropic-backed gateway) via an API bearer
# token, NOT an OAuth login and NOT api.anthropic.com directly; see "Credentials" below.
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
#   * Credentials: the container receives the yscope-anthropic-paper-validation profile env
#     (ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN, plus the model-default / non-essential-
#     traffic flags) via `docker run --env-file`, produced by
#     `context/extract-yscope-anthropic-paper-validation-env.sh`. The token is a long-lived API bearer token
#     (NOT expiring OAuth), so runs no longer break on host token rotation. The token is a
#     SECRET — the env-file lives outside the repo (e.g. /tmp, chmod 600) and is NEVER
#     committed. The script refuses to run unless ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN
#     are present, so it can never silently fall back to a login prompt or a different
#     endpoint. See METHODOLOGY.md §11.
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

# ---- Pinned subject: Claude Opus 4.7 via the yscope-anthropic-paper-validation profile ----------------
# The diagnosis subject is Claude Opus 4.7 (`claude-opus-4-7`, effort high), reached through
# the `ccs yscope-anthropic-paper-validation` profile — the org's Anthropic-backed gateway. Auth is an API
# bearer token (ANTHROPIC_AUTH_TOKEN) to that gateway (ANTHROPIC_BASE_URL), NOT an OAuth
# login and NOT api.anthropic.com directly: a long-lived token avoids the OAuth
# access-token-expiry / host-rotation 401s that broke the earlier subscribed-account runs.
# Override per-run via env only if you intentionally change the subject. NOTE: pin a full
# model ID, NOT the `opus` alias — the alias drifts to whatever is "latest" on run day.
MODEL="${CLODS_MODEL:-claude-opus-4-7}"   # Opus 4.7
EFFORT="${CLODS_EFFORT:-high}"

# The container MUST receive the yscope-anthropic-paper-validation env. Refuse to run without it, so we
# never silently fall back to an anonymous/login-prompt or a different endpoint. Inject via
# `docker run --env-file` (see context/extract-yscope-anthropic-paper-validation-env.sh + METHODOLOGY §11).
: "${ANTHROPIC_BASE_URL:?run_diagnosis.sh: ANTHROPIC_BASE_URL must be set (the yscope-anthropic-paper-validation gateway URL; inject via --env-file)}"
: "${ANTHROPIC_AUTH_TOKEN:?run_diagnosis.sh: ANTHROPIC_AUTH_TOKEN must be set (the yscope-anthropic-paper-validation API token; inject via --env-file)}"

# Derive the egress host from the configured endpoint (the yscope-anthropic-paper-validation gateway). The
# docker run must pin this host's IP with --add-host <host>:<ip> so /etc/hosts resolves it
# after the iptables DROP policy kills DNS (getent then reads /etc/hosts, no network DNS).
GATEWAY_HOST="$(python3 - <<'PY'
import os, urllib.parse as u
print(u.urlparse(os.environ.get("ANTHROPIC_BASE_URL", "")).hostname or "")
PY
)"
[ -n "$GATEWAY_HOST" ] || { echo "ERROR: cannot parse gateway host from ANTHROPIC_BASE_URL='$ANTHROPIC_BASE_URL'" >&2; exit 1; }

# How to invoke the CLI. Default `claude` is the container path; the yscope-anthropic-paper-validation env
# (above) authenticates it, so the strongest purity flag `--bare` works here — env-token
# auth needs no keychain, and `--bare` skips CLAUDE.md/skills/plugins/hooks/keychain. (On a
# host without the env injected, run via the wrapper: CLAUDE_CMD="ccs yscope-anthropic-paper-validation",
# which sets the same env.) Left unquoted below so a multi-word prefix word-splits.
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
PURITY_FLAG="${CLAUDE_PURITY_FLAG:---bare}"

# ---- Lock the network: DROP everything, then allow only the model gateway ------------
# Best-effort: if we lack NET_ADMIN, warn but continue (the prompt + denied web tools
# still enforce the rule at the agent layer). The yscope-anthropic-paper-validation env sets
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1, so no statsig/telemetry sub-calls are made —
# only the gateway host needs to be reachable.
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
    for host in "$GATEWAY_HOST"; do
        for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
            iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
        done
    done
    echo "Network locked: egress restricted to $GATEWAY_HOST:443 (the yscope-anthropic-paper-validation gateway)." >&2
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