#!/usr/bin/env bash
# run_diagnosis.subscription.sh — HBase-4078's SUBSCRIPTION variant of run_diagnosis.yscope.sh.
#
# Why: the org gateway (yscope-anthropic-paper-validation) exhausted its daily claude-opus-4-7
# quota after 2 of the 5 runs. At the operator's instruction the remaining runs use the
# operator's OWN Anthropic subscription (the `ccs anthropic` account profile, Max plan) against
# the real api.anthropic.com endpoint. The SUBJECT IS UNCHANGED: claude-opus-4-7, effort high —
# verified per-run from the CLI's own modelUsage metadata.
#
# Deltas vs run_diagnosis.yscope.sh — exactly three, all about auth/egress, none about the
# experiment: (1) auth via an isolated COPY of the account profile's .credentials.json mounted
# at $CLAUDE_CONFIG_DIR instead of the gateway's bearer-token env-file; (2) egress locked to
# api.anthropic.com instead of the gateway host; (3) purity flag --safe-mode instead of --bare,
# because --bare skips the keychain and so refuses account auth (CLAUDE_PURITY_FLAG is the
# tracked script's own knob for this). The prompt, the staging rules, the tool denials, the
# statelessness, the single turn and the model/effort pinning are byte-identical.
#
# ---- prodlog header below ----
# run_diagnosis.yscope.sh — HBase-4078's copy of context/run_diagnosis.sh.
#
# context/ is read-only for agents (METHODOLOGY §13) and the tracked harness has not caught
# up with two things the current methodology requires, so this copy applies exactly those two
# deltas and NOTHING else — every isolation, staging, tool-denial, statelessness, credential
# and model/effort property is byte-identical to the tracked script:
#   1. §5/M6's prompt text — "the production log at <STAGE>/logs/symptom.log (this is a large,
#      realistic production log — grep it for the symptom rather than reading it whole)".
#   2. §7's staging rule — hardlink the 3.19 GB merged log into the staging dir instead of
#      copying it once per run (falls back to a copy across filesystems).
# The diff against context/run_diagnosis.sh is exactly these two hunks plus this header.
#
# ---- original header below ----
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

# SUBSCRIPTION DELTA 1 — auth. This variant authenticates with the operator's own Anthropic
# subscription (the `ccs anthropic` ACCOUNT profile), which keeps its credentials in a config
# directory rather than in env vars (`ccs env anthropic` yields only CLAUDE_CONFIG_DIR). The
# container therefore receives an ISOLATED COPY of that profile's `.credentials.json` mounted
# at $CLAUDE_CONFIG_DIR — a copy, so the container (running as root) can never write to or
# invalidate the operator's real profile, and so none of that profile's history, projects, MCP
# servers or memories come with it. Refuse to run without it, so we can never silently fall
# back to a login prompt, an anonymous session or a different endpoint.
: "${CLAUDE_CONFIG_DIR:?run_diagnosis.subscription.sh: CLAUDE_CONFIG_DIR must point at a copy of the ccs 'anthropic' profile dir holding .credentials.json (mount it with -v)}"
[ -s "$CLAUDE_CONFIG_DIR/.credentials.json" ] || {
    echo "ERROR: no .credentials.json in CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" >&2; exit 1; }

# SUBSCRIPTION DELTA 2 — egress. The subscription account talks to Anthropic directly, so the
# single allowed host is api.anthropic.com instead of the org gateway. The docker run must pin
# its IPs with --add-host so /etc/hosts still resolves it after the DROP policy kills DNS.
GATEWAY_HOST="${CLODS_API_HOST:-api.anthropic.com}"

# How to invoke the CLI. Default `claude` is the container path; the yscope-anthropic-paper-validation env
# (above) authenticates it, so the strongest purity flag `--bare` works here — env-token
# auth needs no keychain, and `--bare` skips CLAUDE.md/skills/plugins/hooks/keychain. (On a
# host without the env injected, run via the wrapper: CLAUDE_CMD="ccs yscope-anthropic-paper-validation",
# which sets the same env.) Left unquoted below so a multi-word prefix word-splits.
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
# SUBSCRIPTION DELTA 3 — purity flag. `--bare` skips the keychain and therefore refuses
# OAuth/account auth ("Not logged in"); `--safe-mode` is the knob the tracked script already
# exposes for exactly this case (CLAUDE_PURITY_FLAG) and keeps auth while still disabling
# CLAUDE.md discovery, auto-memory, skills, plugins and hooks. The mounted config dir holds
# ONLY .credentials.json plus a minimal .claude.json, so there is nothing else to leak in.
PURITY_FLAG="${CLAUDE_PURITY_FLAG:---safe-mode}"

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
    echo "Network locked: egress restricted to $GATEWAY_HOST:443 (the Anthropic API)." >&2
}
lock_network

# ---- Build a CLEAN staging dir: only the inputs the diagnosis LLM may see --------
# private/ is deliberately NOT copied in, so the answer key is unreachable regardless of
# how the container was mounted.
STAGE="$(mktemp -d -t clods-diag-XXXX)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/logs"
cp -a "$SOURCE_DIR"            "$STAGE/source"
# DELTA 2 (§7): the merged production log is GB-scale and is staged for each of the 5 runs;
# stage it read-only via hardlink (falling back to a copy across filesystems), never a copy.
ln "$LOG_FILE" "$STAGE/logs/symptom.log" 2>/dev/null || cp -a "$LOG_FILE" "$STAGE/logs/symptom.log"
cp -a "$SYMPTOM_FILE"          "$STAGE/symptom.md"

STAGE_SRC="$STAGE/source"
STAGE_LOG="$STAGE/logs/symptom.log"
SYMPTOM="$(cat "$STAGE/symptom.md")"

# ---- The single fixed prompt (methodology §5/M6) --------------------------
# Paths point into STAGE only. The agent never learns /bug or private/ exist.
read -r -d '' PROMPT <<EOF || true
Given the source code at $STAGE_SRC and the production log at $STAGE_LOG (this is a large, realistic production log — grep it for the symptom rather than reading it whole), what is the root cause of the failure: $SYMPTOM? Identify the specific lines of code and the exact logical conditions (branches) that dictate this failure path.

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