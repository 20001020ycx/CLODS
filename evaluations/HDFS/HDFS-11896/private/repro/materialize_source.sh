#!/usr/bin/env bash
# Regenerate the gitignored source/ (LLM-facing anonymized tree) and the
# anonymized logs/symptom.log from the committed canonical copies.
set -euo pipefail
BUG="$(cd "$(dirname "$0")/../.." && pwd)"
rm -rf "$BUG/source" && mkdir -p "$BUG/source"
cp -r "$BUG/private/anon-source/src" "$BUG/source/"
mkdir -p "$BUG/logs"; cp "$BUG/private/symptom.anon.log" "$BUG/logs/symptom.log"
# sanity: compile + reproduce
tmp=$(mktemp -d)
javac -d "$tmp" $(find "$BUG/source/src/main/java" -name '*.java')
javac -cp "$tmp" -d "$tmp" "$BUG/private/repro/ReproDriver.java"
java -cp "$tmp" ReproDriver | grep -E 'REPRO_RESULT'
echo "source/ and logs/symptom.log materialized."
