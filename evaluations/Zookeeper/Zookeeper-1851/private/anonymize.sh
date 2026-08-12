#!/usr/bin/env bash
# anonymize.sh — Zookeeper-1851 (M4). Deterministically regenerates the two gitignored,
# LLM-facing artifacts from tracked metadata:
#
#   <BUG_DIR>/source/            — the real pre-fix ZooKeeper Java source, renamed
#   <BUG_DIR>/logs/symptom.log   — the reproduction log, produced by the RENAMED build
#
# Steps (see private/anonymization_map.json for the rationale of each rename):
#   1. clone the system repo at pre_fix_commit into a NEUTRAL path (the JVM prints
#      user.dir / the classpath into the log, so the path must not name the bug);
#   2. apply private/deps-fix.patch (the 2014 build on a modern toolchain);
#   3. rename the distinctive term  create2 -> createExt  /  Create2 -> CreateExt
#      across src/java/**/*.java and src/zookeeper.jute, including the two proto files;
#   4. `ant jar` the renamed tree — the rename must compile, and the log must come from
#      the renamed binaries, not from a rewritten log file;
#   5. copy src/java/main + src/java/generated into source/;
#   6. re-run reproduce.sh against the renamed build, writing logs/symptom.log.
#
# Run INSIDE the per-bug container:
#   docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1851 \
#       -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1851/private/anonymize.sh'
set -euo pipefail

BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1851}"
SRC_CLONE="${SRC_CLONE:-/work/repos/Zookeeper-Zookeeper-1851}"      # or the github URL
ANON_REPO="${ANON_REPO:-/work/repos/zookeeper-quorum-src}"          # neutral: the JVM
                                                                    # prints user.dir + the
                                                                    # classpath into the log
PRE_FIX="${PRE_FIX:-25ea38a87b73edfe934886a51b694fe9493a2be2}"

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
# src/java/generated/ is not in the repo: the Jute compiler produces it from
# src/zookeeper.jute during the build, so renaming the record there renames
# Create2Request/Create2Response and their files automatically at step 4.
# NB: plain substring replacement, not \bcreate2\b - local variables such as
# `create2Txn` / `create2Request` have no word boundary after the digit.
find src/java -name '*.java' -print0 | xargs -0 sed -i \
    -e 's/create2/createExt/g' \
    -e 's/Create2/CreateExt/g'
sed -i -e 's/create2/createExt/g' -e 's/Create2/CreateExt/g' src/zookeeper.jute

# ---- 4. rebuild the renamed tree --------------------------------------------------------
ant jar

leaks="$(grep -rEli 'create2' src/java src/zookeeper.jute || true)"
if [ -n "$leaks" ]; then
    echo "ERROR: rename missed files:"; echo "$leaks"; exit 1
fi

# ---- 5. source/ = the renamed pre-fix Java source ---------------------------------------
rm -rf "$BUG_DIR/source"
mkdir -p "$BUG_DIR/source/src/java"
cp -a src/java/main      "$BUG_DIR/source/src/java/main"
cp -a src/java/generated "$BUG_DIR/source/src/java/generated"

# ---- 6. regenerate the symptom log from the RENAMED build --------------------------------
REPO="$ANON_REPO" BUG_DIR="$BUG_DIR" OUT_LOG="$BUG_DIR/logs/symptom.log" \
    bash "$BUG_DIR/reproduce.sh"
rc=$?

echo "[anonymize] reproduce.sh exit=$rc"
echo "[anonymize] source/ = $(find "$BUG_DIR/source" -name '*.java' | wc -l) java files"
echo "[anonymize] logs/symptom.log = $(wc -l < "$BUG_DIR/logs/symptom.log") lines"

# ---- 7. leakage verification (METHODOLOGY 6) --------------------------------------------
bad=0
for pat in 'ZOOKEEPER-1851' '\b1851\b' 'create2'; do
    hits="$(grep -rEic -- "$pat" "$BUG_DIR/source" "$BUG_DIR/logs/symptom.log" \
            "$BUG_DIR/symptom.md" 2>/dev/null | grep -v ':0$' || true)"
    if [ -n "$hits" ]; then
        echo "[anonymize] LEAK for /$pat/:"; echo "$hits"; bad=1
    else
        echo "[anonymize] clean for /$pat/"
    fi
done
[ "$bad" -eq 0 ] || exit 1
exit $rc
