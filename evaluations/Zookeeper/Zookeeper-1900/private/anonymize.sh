#!/usr/bin/env bash
# anonymize.sh — Zookeeper-1900 (M4). Deterministically regenerates the gitignored,
# LLM-facing artifacts from tracked metadata:
#
#   <BUG_DIR>/source/            — the pre-fix ZooKeeper Java source, anonymized
#   <BUG_DIR>/logs/repro.log     — Log A: the standalone reproduction, from the anon build
#   <BUG_DIR>/logs/symptom.log   — Log B: Log A merged into the shared production log (LLM-facing)
#
# Per METHODOLOGY.md M4 / §6 the anonymization is four things, all recorded in
# private/anonymization_map.json:
#   (a) bug-id scrub;
#   (b) distinctive-term rename            truncate/TRUNC -> rollBack/ROLLBACK
#       (the ticket is titled "NullPointerException in truncate");
#   (c) failure-path FILE/TYPE rename      FileTxnLog -> TxnJournal, QuorumPeer -> EnsembleMember, ...
#       (blocks "I recognize FileTxnLog.truncate -> this is ZOOKEEPER-1900");
#   (d) failure-path LOG-STATEMENT rewrite "Unexpected exception" -> "Unhandled error in the
#       peer state machine", etc. (blocks string-matching the log against known reports).
# Then both logs are regenerated from the anonymized build so their literals and stack
# frames match source/.
#
# All of (b),(c),(d) are ONE substitution map applied in a SINGLE pass (longest key first),
# so a replacement can never be re-replaced (e.g. Observer -> ObserverPeer stays put) and
# keys always match the pristine upstream spelling.
#
# NOTE on the production stream: the shared production log is real ZooKeeper output, so it
# contains the very class names and log wording (c)/(d) change — 2.19M lines mentioning
# LearnerHandler and 1.90M mentioning QuorumPeer[myid=. The same map is therefore applied to
# the production stream *while building this bug's merged log*, so the merged log is
# self-consistent with source/ and the original names cannot be recovered from the noise.
# The shared production log itself is READ-ONLY and never modified.
#
# Run INSIDE the per-bug container:
#   docker run --rm -v "$PWD:/work" clods-eval:Zookeeper-Zookeeper-1900 \
#       -c 'bash /work/evaluations/Zookeeper/Zookeeper-1900/private/anonymize.sh'
set -euo pipefail

BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1900}"
SRC_CLONE="${SRC_CLONE:-/work/repos/Zookeeper-Zookeeper-1900}"
ANON_REPO="${ANON_REPO:-/work/repos/zookeeper-ensemble-src}"        # neutral: the JVM
                                                                    # prints user.dir + the
                                                                    # classpath into the log
PROD_LOG="${PROD_LOG:-/work/production-logs/Zookeeper/production.log}"   # read-only
PRE_FIX="${PRE_FIX:-8cfb9a0efa5c8934eb3c95ca69566c718a37d9ca}"

git config --global --add safe.directory '*'

# ---- 0. the substitution map (single source of truth for every rewrite) ------------------
MAP="$BUG_DIR/private/.anon-map.json"
cat > "$MAP" <<'JSON'
{
  "Truncating log to get in sync with the leader": "Rewinding the transaction journal to match the leader",
  "Not able to truncate the log": "Unable to rewind the transaction journal",
  "Unable to truncate {}": "Unable to discard {}",
  "Sending TRUNC to follower zxidToSend=0x": "Instructing peer to rewind to zxid=0x",
  "Sending TRUNC zxid=0x": "Instructing peer to rewind to zxid=0x",
  "Cannot send TRUNC to peer sid: ": "Cannot rewind peer sid: ",
  "Synchronizing with Follower sid: ": "Bringing peer up to date, sid: ",
  "Getting a diff from the leader 0x": "Receiving a delta from the leader 0x",
  "Received NEWLEADER-ACK message from ": "Got NEWLEADER acknowledgement from ",
  "Unexpected exception": "Unhandled error in the peer state machine",
  "PeerState set to ": "Peer state changed to ",
  "Exception when observing the leader": "Error while following the current leader",
  "shutdown called": "role shutdown requested",
  "Created new input stream": "Opened journal segment for reading",
  "Created new input archive": "Journal segment reader ready",
  "Creating new log file: ": "Starting new journal segment: ",
  "Snapshotting: 0x": "Writing state snapshot: 0x",

  "truncateLog": "rollBackLog",
  "truncated": "rolledBack",
  "truncating": "rewinding",
  "truncation": "rewind",
  "truncate": "rollBack",
  "truncLog": "rbLog",
  "TruncateTest": "RollBackTest",
  "Truncating": "Rewinding",
  "Truncation": "Rewind",
  "Truncate": "RollBack",
  "TRUNC": "ROLLBACK",
  "truncat": "rollBack",
  "Truncat": "RollBack",

  "FileTxnSnapLog": "JournalSnapStore",
  "FileTxnIterator": "TxnJournalIterator",
  "FileTxnLog": "TxnJournal",
  "ZKDatabase": "ZKStateStore",
  "zkDatabase": "zkStateStore",
  "zkdatabase": "zkstatestore",
  "LearnerHandler": "PeerSyncHandler",
  "Learner": "PeerSynchronizer",
  "QuorumPeer": "EnsembleMember",
  "quorumPeer": "ensembleMember",
  "Observer": "ObserverPeer"
}
JSON

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

# ---- 3. anonymize: one single-pass substitution over src/java, then rename the files ----
python3 - "$MAP" <<'PY'
import json, os, re, subprocess, sys
m = json.load(open(sys.argv[1]))
pat = re.compile("|".join(re.escape(k) for k in sorted(m, key=len, reverse=True)))
sub = lambda s: pat.sub(lambda x: m[x.group(0)], s)          # noqa: E731
files = subprocess.check_output(
    ["find", "src/java", "-type", "f", "-name", "*.java", "-o",
     "-type", "f", "-name", "*.xml", "-o",
     "-type", "f", "-name", "*.properties"]).decode().split()
# src/zookeeper.jute defines the wire records the Jute compiler turns into
# src/java/generated/**.java at build time (e.g. LearnerInfo). It must be substituted too,
# or the generated classes keep the original names and the tree will not compile.
files.append("src/zookeeper.jute")
for f in files:
    s = open(f, encoding="utf-8", errors="surrogateescape").read()
    o = sub(s)
    if o != s:
        open(f, "w", encoding="utf-8", errors="surrogateescape").write(o)
# a Java file name must match the public type it declares
for f in [x for x in files if x.endswith(".java")]:
    d, b = os.path.dirname(f), os.path.basename(f)
    nb = sub(b)
    if nb != b:
        os.rename(f, os.path.join(d, nb))
print("[anonymize] substituted %d java files" % len(files))
PY

# ---- 4. rebuild the anonymized tree ------------------------------------------------------
ant jar

leaks="$(grep -rEl '[Tt]runcat|\bTRUNC\b|FileTxnLog|FileTxnSnapLog|ZKDatabase|\bLearner\b|\bQuorumPeer\b|\bObserver\b' src/java || true)"
[ -z "$leaks" ] || { echo "ERROR: anonymization missed files:"; echo "$leaks"; exit 1; }

# ---- 5. source/ = the anonymized pre-fix Java source -------------------------------------
rm -rf "$BUG_DIR/source"
mkdir -p "$BUG_DIR/source/src/java"
cp -a src/java/main      "$BUG_DIR/source/src/java/main"
cp -a src/java/generated "$BUG_DIR/source/src/java/generated"

# ---- 6. regenerate BOTH logs from the anonymized build -----------------------------------
# Log A: the standalone reproduction, straight from the anonymized binaries. The entry point
# was renamed with everything else (QuorumPeerMain -> EnsembleMemberMain).
rc=0
REPO="$ANON_REPO" BUG_DIR="$BUG_DIR" OUT_LOG="$BUG_DIR/logs/repro.log" \
  MAIN_CLASS="org.apache.zookeeper.server.quorum.EnsembleMemberMain" \
  bash "$BUG_DIR/reproduce.sh" || rc=$?
[ "$rc" -eq 0 ] || { echo "[anonymize] FATAL: the anonymized build no longer reproduces"; exit "$rc"; }
echo "[anonymize] reproduce.sh exit=$rc"

# Log B: Log A merged into the shared production log, with the same map applied to the
# production stream so the whole merged log is consistent with source/.
python3 "$BUG_DIR/private/merge_logs.py" \
    --production "$PROD_LOG" \
    --repro      "$BUG_DIR/logs/repro.log" \
    --out        "$BUG_DIR/logs/symptom.log" \
    --interleave position \
    --rename     "$MAP"

echo "[anonymize] source/            = $(find "$BUG_DIR/source" -name '*.java' | wc -l) java files"
echo "[anonymize] logs/repro.log     = $(wc -l < "$BUG_DIR/logs/repro.log") lines"
echo "[anonymize] logs/symptom.log   = $(wc -l < "$BUG_DIR/logs/symptom.log") lines"

# ---- 7. leakage verification (METHODOLOGY §6) --------------------------------------------
bad=0
for pat in 'ZOOKEEPER-1900' '\b1900\b' '[Tt]runcat' '\bTRUNC\b' \
           'FileTxnLog' 'FileTxnSnapLog' 'FileTxnIterator' 'ZKDatabase' \
           '\bLearner\b' 'LearnerHandler' '\bQuorumPeer\b' '\bObserver\b'; do
    hits=""
    for f in "$BUG_DIR/source" "$BUG_DIR/logs/repro.log" "$BUG_DIR/logs/symptom.log" "$BUG_DIR/symptom.md"; do
        [ -e "$f" ] || continue
        c="$(LC_ALL=C grep -rEc -- "$pat" "$f" 2>/dev/null | grep -v ':0$' || true)"
        [ -n "$c" ] && hits="$hits $f"
    done
    if [ -n "$hits" ]; then echo "[anonymize] LEAK for /$pat/ in:$hits"; bad=1
    else echo "[anonymize] clean for /$pat/"; fi
done
[ "$bad" -eq 0 ] || exit 1
exit 0
