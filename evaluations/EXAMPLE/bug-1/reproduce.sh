#!/usr/bin/env bash
# reproduce.sh — bug-1 (EXAMPLE). Reproduces the spurious-retry failure.
# Built from source at the pre-fix commit (M2); deps fixed via private/deps-fix.patch.
# This is an illustrative stub for the published example.
set -euo pipefail
BUG_DIR="$(cd "$(dirname "$0")" && pwd)"

# M2: build the failure-path module from source (idempotent).
# (cd "$BUG_DIR/source" && mvn -pl mod1 -am package -DskipTests -q)

# M3: run the targeted unit test that drives RetryHandler with a PARTIAL_ACK response,
# which the pre-fix `response != OK` guard misclassifies as "must retry".
java -cp "$BUG_DIR/source/mod1/target/classes" org.mod1.RetryHandlerTest \
    > "$BUG_DIR/logs/symptom.log" 2>&1

echo "Reproduction complete; see logs/symptom.log (should contain Event A8 then A7 then a second A9)."