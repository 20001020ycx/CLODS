#!/usr/bin/env bash
# m6-run.sh — HDFS-14135, METHODOLOGY §5/M6 + §11. Run from the repo root ON THE HOST:
#     bash evaluations/HDFS/HDFS-14135/private/m6-run.sh
#
# Starts ONE disposable container that runs private/run_diagnosis.prodlog.sh (the shared
# harness, byte-identical to HBase-3627's copy) for the 5 independent, single-turn,
# network-locked diagnoses.
#
# Subject/endpoint (same as the most recent bugs in this workspace): Claude Opus 4.7 through
# the `ccs anthropic` ACCOUNT — the Claude subscription login (claudeAiOauth) going straight
# to api.anthropic.com. The container therefore carries NO ANTHROPIC_BASE_URL /
# ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY, and the iptables allowlist opens
# api.anthropic.com:443 only. --safe-mode replaces --bare because --bare refuses the mounted
# OAuth credentials.
#
# Staging: the merged log is ~7.4 GB, so TMPDIR points at a scratch volume on the same SSD
# (repos/.diagstage-HDFS-14135) instead of the container's overlay filesystem. The harness
# hardlinks the log when it can and falls back to a copy across mounts.
set -euo pipefail

ROOT="${ROOT:-/mnt/SSD-4T/ycx/CLODS}"
BUG_DIR="$ROOT/evaluations/HDFS/HDFS-14135"
CRED_SRC="${CRED_SRC:-$HOME/.ccs/instances/anthropic}"
CRED="$(mktemp -d /tmp/clods-cred-XXXX)"
STAGE_VOL="$ROOT/repos/.diagstage-HDFS-14135"
LOGF="$BUG_DIR/private/m6-harness.log"

cleanup() { rm -rf "$CRED"; }
trap cleanup EXIT

install -m 600 "$CRED_SRC/.credentials.json" "$CRED/.credentials.json"
install -m 600 "$CRED_SRC/.claude.json"      "$CRED/.claude.json"
mkdir -p "$STAGE_VOL"

API_IP="$(getent ahostsv4 api.anthropic.com | awk '{print $1}' | sort -u | head -1)"
[ -n "$API_IP" ] || { echo "cannot resolve api.anthropic.com" >&2; exit 1; }

{
  echo "=== M6 provenance (subject/endpoint evidence) ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "api.anthropic.com pinned to: $API_IP"
} >> "$LOGF"

docker run --rm --name clods-diag-hdfs14135 --cap-add=NET_ADMIN \
  --add-host "api.anthropic.com:$API_IP" \
  -v "$BUG_DIR:/bug" \
  -v "$CRED:/root/.claude" \
  -v "$STAGE_VOL:/stage" \
  -e CLAUDE_CONFIG_DIR=/root/.claude -e IS_SANDBOX=1 \
  -e CLAUDE_PURITY_FLAG=--safe-mode -e TMPDIR=/stage \
  --entrypoint bash clods-eval -lc '
    echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-<unset>}   ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:+<set>}${ANTHROPIC_AUTH_TOKEN:-<unset>}   ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-<unset>}"
    python3 -c "import json;d=json.load(open(\"/root/.claude/.credentials.json\"));print(\"credential kind:\", list(d.keys()), d.get(\"claudeAiOauth\",{}).get(\"subscriptionType\"))"
    grep -m1 api /etc/hosts
    echo "=== harness ==="
    bash /bug/private/run_diagnosis.prodlog.sh /bug
    echo "=== iptables after lock ==="
    iptables -S
  ' 2>&1 | tee -a "$LOGF"

echo "[m6] done; provenance appended to $LOGF"
