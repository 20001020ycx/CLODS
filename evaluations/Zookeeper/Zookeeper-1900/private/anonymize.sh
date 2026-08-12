#!/usr/bin/env bash
# anonymize.sh — Zookeeper-1900 (M4). Deterministically regenerates the two gitignored,
# LLM-facing artifacts from tracked metadata:
#
#   <BUG_DIR>/source/            — the real pre-fix ZooKeeper Java source, renamed
#   <BUG_DIR>/logs/symptom.log   — the reproduction log, produced by the RENAMED build
#
# Steps (see private/anonymization_map.json for the rationale of each rename):
#   1. clone the system repo at pre_fix_commit into a NEUTRAL path (the JVM prints
#      user.dir / the classpath into the log, so the path must not name the bug);
#   2. apply private/deps-fix.patch (the 2014 build on a modern toolchain);
#   3. rename the distinctive term that names the JIRA case — the transaction-log
#      *truncation* vocabulary — to a neutral synonym (roll back), and rewrite the two
#      log messages the ticket quotes;
#   4. `ant jar` the renamed tree — the rename must compile, and the log must come from
#      the renamed binaries, not from a rewritten log file;
#   5. copy src/java/main + src/java/generated into source/;
#   6. re-run reproduce.sh against the renamed build, writing logs/symptom.log.
#
# Run INSIDE the per-bug container:
#   docker run --rm -v "$PWD:/work" clods-eval:Zookeeper-Zookeeper-1900 \
#       -c 'bash /work/evaluations/Zookeeper/Zookeeper-1900/private/anonymize.sh'
set -euo pipefail

BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1900}"
SRC_CLONE="${SRC_CLONE:-/work/repos/Zookeeper-Zookeeper-1900}"      # or the github URL
ANON_REPO="${ANON_REPO:-/work/repos/zookeeper-ensemble-src}"        # neutral: the JVM
                                                                    # prints user.dir + the
                                                                    # classpath into the log
PRE_FIX="${PRE_FIX:-8cfb9a0efa5c8934eb3c95ca69566c718a37d9ca}"

# the container runs as root over a host-owned bind mount
git config --global --add safe.directory '*'

# ---- 1. fresh checkout of the pre-fix tree at a neutral path ---------------------------
if [ ! -d "$ANON_REPO/.git" ]; then
    rm -rf "$ANON_REPO"
    git clone --quiet "$SRC_CLONE" "$ANON_REPO"
fi
cd "$ANON_REPO"
git checkout --quiet --force "$PRE_FIX"
git clean -qfdx -e build || true          # keep the ivy-resolved build/lib if present
git checkout --quiet -- .

# ---- 2. dependency fixes (identical to the M2 build) -----------------------------------
git apply "$BUG_DIR/private/deps-fix.patch"

# ---- 3. the rename ---------------------------------------------------------------------
# (a) the log messages the JIRA report quotes verbatim, rewritten in the new vocabulary;
# (b) the identifiers of the truncation API itself.
find src/java -name '*.java' -print0 | xargs -0 sed -i \
    -e 's/Truncating log to get in sync with the leader/Rolling back the transaction log to get in sync with the leader/g' \
    -e 's/Unable to truncate {}/Unable to roll back {}/g' \
    -e 's/Not able to truncate the log/Not able to roll back the log/g' \
    -e 's/to truncate the previous bytes of string/to trim the previous bytes of string/g' \
    -e 's/\btruncateLog\b/rollBackLog/g' \
    -e 's/\btruncate\b/rollBack/g' \
    -e 's/\btruncated\b/rolledBack/g' \
    -e 's/\btruncLog\b/rbLog/g' \
    -e 's/\bTRUNC\b/ROLLBACK/g'

# ---- 4. rebuild the renamed tree --------------------------------------------------------
ant jar

leaks="$(grep -rElw 'truncate\|truncateLog\|truncated\|TRUNC\|Truncating' src/java || true)"
if [ -n "$leaks" ]; then
    echo "ERROR: rename missed files:"; echo "$leaks"; exit 1
fi

# ---- 5. source/ = the renamed pre-fix Java source ---------------------------------------
rm -rf "$BUG_DIR/source"
mkdir -p "$BUG_DIR/source/src/java"
cp -a src/java/main      "$BUG_DIR/source/src/java/main"
cp -a src/java/generated "$BUG_DIR/source/src/java/generated"

# ---- 6. regenerate the symptom log from the RENAMED build --------------------------------
set +e
REPO="$ANON_REPO" BUG_DIR="$BUG_DIR" OUT_LOG="$BUG_DIR/logs/symptom.log" \
    bash "$BUG_DIR/reproduce.sh"
rc=$?
set -e

echo "[anonymize] reproduce.sh exit=$rc"
echo "[anonymize] source/ = $(find "$BUG_DIR/source" -name '*.java' | wc -l) java files"
echo "[anonymize] logs/symptom.log = $(wc -l < "$BUG_DIR/logs/symptom.log") lines"

# ---- 7. leakage verification (METHODOLOGY 6) --------------------------------------------
bad=0
for pat in 'ZOOKEEPER-1900' '\b1900\b' '[Tt]runcat' '\bTRUNC\b'; do
    hits="$(grep -rEc -- "$pat" "$BUG_DIR/source" "$BUG_DIR/logs/symptom.log" \
            "$BUG_DIR/symptom.md" 2>/dev/null | grep -v ':0$' || true)"
    if [ -n "$hits" ]; then
        echo "[anonymize] LEAK for /$pat/:"; echo "$hits" | head -20; bad=1
    else
        echo "[anonymize] clean for /$pat/"
    fi
done
[ "$bad" -eq 0 ] || exit 1
exit $rc
