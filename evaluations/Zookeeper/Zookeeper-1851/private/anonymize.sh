#!/usr/bin/env bash
# anonymize.sh — Zookeeper-1851 (M4). Deterministically regenerates the gitignored,
# LLM-facing artifacts from tracked metadata:
#
#   <BUG_DIR>/source/            — the pre-fix ZooKeeper Java source, anonymized
#   <BUG_DIR>/logs/repro.log     — Log A: the standalone reproduction, from the anon build
#   <BUG_DIR>/logs/symptom.log   — Log B: Log A merged into the shared production log (LLM-facing)
#
# Per METHODOLOGY.md M4 / §6 the anonymization is four things, all recorded in
# private/anonymization_map.json:
#   (a) bug-id scrub;
#   (b) distinctive-term rename            create2 -> createExt;
#   (c) failure-path FILE/TYPE rename      e.g. CommitProcessor -> StagedRequestProcessor
#       (blocks "I recognize FollowerRequestProcessor -> this is ZOOKEEPER-1851");
#   (d) failure-path LOG-STATEMENT rewrite e.g. "Processing request:: " -> "Handling submission:: "
#       (blocks string-matching the log against known reports).
# Then both logs are regenerated from the anonymized build so their literals and stack
# frames match source/.
#
# NOTE on the production stream: the shared production log is real ZooKeeper output, so it
# contains the very class names and log wording (c)/(d) change — 5.5M lines mentioning
# CommitProcessor alone. The same map is therefore applied to the production stream *while
# building this bug's merged log*, so the merged log is self-consistent with source/ and the
# original names cannot be recovered from the noise. The shared production log itself is
# READ-ONLY and never modified.
#
# Run INSIDE the per-bug container:
#   docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1851 \
#       -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1851/private/anonymize.sh'
set -euo pipefail

BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1851}"
SRC_CLONE="${SRC_CLONE:-/work/repos/Zookeeper-Zookeeper-1851}"
ANON_REPO="${ANON_REPO:-/work/repos/zookeeper-quorum-src}"          # neutral: the JVM
                                                                    # prints user.dir + the
                                                                    # classpath into the log
PROD_LOG="${PROD_LOG:-/work/production-logs/Zookeeper/production.log}"   # read-only
PRE_FIX="${PRE_FIX:-25ea38a87b73edfe934886a51b694fe9493a2be2}"

git config --global --add safe.directory '*'

# ---- 0. the anonymization map (single source of truth for every rewrite) ----------------
# (d) log literals are applied BEFORE (c) type renames, because some literals embed the old
# class name and get neutral wording rather than just the new name.
LOG_MAP="$BUG_DIR/private/.log-literals.json"
TYPE_MAP="$BUG_DIR/private/.type-renames.json"
MERGE_MAP="$BUG_DIR/private/.production-rewrite.json"
cat > "$LOG_MAP" <<'JSON'
{
  "Processing request:: ": "Handling submission:: ",
  "Committing request:: ": "Applying agreed submission:: ",
  "Exception thrown by downstream processor,": "Downstream stage failed;",
  " unable to continue.": " cannot continue.",
  "Configuring CommitProcessor with ": "Configuring request staging with ",
  "Unexpected exception causing CommitProcessor to exit": "Fatal error in request staging",
  " exited loop!": " loop terminated",
  "CommitProcWork": "StageWork",
  "Client session timed out, have not heard from server in ": "Session inactive - no server traffic for "
}
JSON
cat > "$TYPE_MAP" <<'JSON'
{
  "FollowerRequestProcessor": "FollowerIngressProcessor",
  "ObserverRequestProcessor": "ObserverIngressProcessor",
  "CommitProcessor": "StagedRequestProcessor",
  "FinalRequestProcessor": "TerminalRequestProcessor",
  "ZKDatabase": "ZKStateStore",
  "WorkerService": "TaskExecutorPool",
  "TraceFormatter": "OpNameFormatter",
  "commitProcessor": "stagedRequestProcessor",
  "CommitWorkRequest": "StageWorkRequest",
  "commitWorkRequest": "stageWorkRequest",
  "zkDatabase": "zkStateStore",
  "zkdatabase": "zkstatestore"
}
JSON
python3 - "$LOG_MAP" "$TYPE_MAP" "$MERGE_MAP" <<'PY'
import json, sys
log, typ, out = (json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3])
m = dict(log); m.update(typ); m["create2"] = "createExt"; m["Create2"] = "CreateExt"
json.dump(m, open(out, "w"), indent=2)
PY

# ---- 1. fresh checkout of the pre-fix tree at a neutral path ---------------------------
if [ ! -d "$ANON_REPO/.git" ]; then
    rm -rf "$ANON_REPO"
    git clone --quiet "$SRC_CLONE" "$ANON_REPO"
fi
cd "$ANON_REPO"
git checkout --quiet --force "$PRE_FIX"
git clean -qfdx -e build || true
git checkout --quiet -- .

# ---- 2. dependency fixes (identical to the M2 build) -----------------------------------
git apply "$BUG_DIR/private/deps-fix.patch"

# ---- 3. anonymize -----------------------------------------------------------------------
# (b) distinctive term. src/java/generated/ is not in the repo — the Jute compiler produces
# it from src/zookeeper.jute during the build, so renaming the record there renames
# Create2Request/Create2Response and their files automatically at step 4. Plain substring
# replacement, not \bcreate2\b: locals such as `create2Txn` have no word boundary.
find src/java -name '*.java' -print0 | xargs -0 sed -i \
    -e 's/create2/createExt/g' -e 's/Create2/CreateExt/g'
sed -i -e 's/create2/createExt/g' -e 's/Create2/CreateExt/g' src/zookeeper.jute

# (d) failure-path log statements, then (c) failure-path file/type names.
python3 - "$LOG_MAP" "$TYPE_MAP" <<'PY'
import json, os, subprocess, sys
log_map, type_map = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
files = subprocess.check_output(
    ["find", "src/java", "-name", "*.java"]).decode().split()
for f in files:
    s = open(f, encoding="utf-8", errors="surrogateescape").read()
    o = s
    for k, v in log_map.items():          # (d) first: some literals embed the old type name
        s = s.replace(k, v)
    for k, v in type_map.items():         # (c)
        s = s.replace(k, v)
    if s != o:
        open(f, "w", encoding="utf-8", errors="surrogateescape").write(s)
# file names must match the public type they contain
for f in files:
    b = os.path.basename(f)
    for k, v in type_map.items():
        if b == k + ".java":
            os.rename(f, os.path.join(os.path.dirname(f), v + ".java"))
PY

# ---- 4. rebuild the anonymized tree ------------------------------------------------------
ant jar

leaks="$(grep -rEli 'create2' src/java src/zookeeper.jute || true)"
[ -z "$leaks" ] || { echo "ERROR: rename missed files:"; echo "$leaks"; exit 1; }

# ---- 5. source/ = the anonymized pre-fix Java source -------------------------------------
rm -rf "$BUG_DIR/source"
mkdir -p "$BUG_DIR/source/src/java"
cp -a src/java/main      "$BUG_DIR/source/src/java/main"
cp -a src/java/generated "$BUG_DIR/source/src/java/generated"

# ---- 6. regenerate BOTH logs from the anonymized build -----------------------------------
# Log A: the standalone reproduction, straight from the anonymized binaries.
rc=0
REPO="$ANON_REPO" BUG_DIR="$BUG_DIR" OUT_LOG="$BUG_DIR/logs/repro.log" \
    bash "$BUG_DIR/reproduce.sh" || rc=$?
[ "$rc" -eq 0 ] || { echo "[anonymize] FATAL: the anonymized build no longer reproduces"; exit "$rc"; }
echo "[anonymize] reproduce.sh exit=$rc"

# Log B: Log A merged into the shared production log, with the same map applied to the
# production stream so the whole merged log is consistent with source/.
python3 "$BUG_DIR/private/merge_logs.py" \
    --production "$PROD_LOG" \
    --repro      "$BUG_DIR/logs/repro.log" \
    --out        "$BUG_DIR/logs/symptom.log" \
    --rename     "$MERGE_MAP"

echo "[anonymize] source/     = $(find "$BUG_DIR/source" -name '*.java' | wc -l) java files"
echo "[anonymize] repro.log   = $(wc -l < "$BUG_DIR/logs/repro.log") lines"
echo "[anonymize] symptom.log = $(wc -l < "$BUG_DIR/logs/symptom.log") lines"

# ---- 7. leakage verification (METHODOLOGY §6) --------------------------------------------
bad=0
check() {  # check <label> <grep-args...>
    local label="$1"; shift
    local hits
    # `|| true` on every stage: grep exits 1 when it matches nothing, which under
    # `set -euo pipefail` would abort the script exactly when the artifacts are clean.
    hits="$( { grep -rEc "$@" 2>/dev/null || true; } | { grep -v ':0$' || true; } )"
    if [ -n "$hits" ]; then
        echo "[anonymize] LEAK ($label):"; echo "$hits" | head; bad=1
    else
        echo "[anonymize] clean: $label"
    fi
}
# symptom.md is M5's artifact (regenerated after this script) and is verified by M5's own gate.
TARGETS=("$BUG_DIR/source" "$BUG_DIR/logs/repro.log" "$BUG_DIR/logs/symptom.log")
check "bug id"            -- 'ZOOKEEPER-1851|\b1851\b' "${TARGETS[@]}"
check "distinctive term"  -i -- 'create2'              "${TARGETS[@]}"
# case-insensitive: a surviving lowercase variable (`commitProcessor`) leaks the type name too
check "orig type names"   -i -- 'FollowerRequestProcessor|ObserverRequestProcessor|CommitProcessor|FinalRequestProcessor|ZKDatabase|WorkerService|TraceFormatter' "${TARGETS[@]}"
check "orig log literals" -- 'Processing request::|Committing request::|Exception thrown by downstream processor|exited loop!|CommitProcWork|Client session timed out' "${TARGETS[@]}"
[ "$bad" -eq 0 ] || exit 1
exit $rc
