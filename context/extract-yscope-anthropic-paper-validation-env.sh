#!/usr/bin/env bash
# extract-yscope-anthropic-paper-validation-env.sh <out-env-file>
#
# Extract the `ccs yscope-anthropic-paper-validation` profile's environment into a plain
# KEY=VALUE file suitable for `docker run --env-file`. This is how the diagnosis container
# receives the Claude Opus 4.7 model credentials (METHODOLOGY.md §11):
#
#   * the yscope-anthropic-paper-validation profile authenticates to the org's
#     Anthropic-backed gateway (https://llm-gateway.yscope.io) with an API bearer token
#     (ANTHROPIC_AUTH_TOKEN), NOT an OAuth login and NOT api.anthropic.com directly;
#   * a long-lived token avoids the OAuth access-token-expiry / host-rotation 401s that
#     broke the earlier subscribed-account runs;
#   * this profile pins the real model IDs as defaults (claude-opus-4-7 / claude-sonnet-4-6
#     / claude-haiku-4-5) rather than the yscope-anthropic-* gateway aliases, so the
#     diagnosis subject is unambiguously Claude Opus 4.7 — the named subject of the paper.
#
# QUOTE PITFALL (why this helper exists): `ccs env yscope-anthropic-paper-validation
# --format raw` emits `export KEY='VALUE'` (shell form, single-quoted). Docker --env-file
# takes the value VERBATIM — it does NOT strip quotes — so a raw env-file would pass the
# token with literal quotes and auth would fail for every run. This helper strips both the
# `export ` prefix and the surrounding single/double quotes.
#
# The output contains a SECRET (ANTHROPIC_AUTH_TOKEN). NEVER commit it: write it OUTSIDE the
# repo (e.g. /tmp), it is chmod 600, and delete it after the diagnosis run.
#
# Usage:
#   bash context/extract-yscope-anthropic-paper-validation-env.sh /tmp/ysa.env
#   docker run --rm --cap-add=NET_ADMIN \
#     --add-host "llm-gateway.yscope.io:$(getent ahostsv4 llm-gateway.yscope.io | awk '{print $1}' | head -1)" \
#     --env-file /tmp/ysa.env ... clods-eval   # see METHODOLOGY.md §11 for the full command
set -euo pipefail

out="${1:?usage: extract-yscope-anthropic-paper-validation-env.sh <out-env-file>}"
umask 077

ccs env yscope-anthropic-paper-validation --format raw 2>/dev/null | python3 -c '
import sys, re
for line in sys.stdin:
    line = line.rstrip("\n")
    m = re.match(r"^export\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
    if not m:
        continue
    k, v = m.group(1), m.group(2)
    if (v[:1] == "\x27" and v[-1:] == "\x27") or (v[:1] == "\"" and v[-1:] == "\""):
        v = v[1:-1]
    print(f"{k}={v}")
' > "$out"

chmod 600 "$out"
echo "wrote $out ($(wc -l < "$out") vars, chmod 600). Contains ANTHROPIC_AUTH_TOKEN — do NOT commit; delete after the run." >&2