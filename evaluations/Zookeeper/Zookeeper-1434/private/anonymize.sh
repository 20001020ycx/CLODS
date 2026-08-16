#!/usr/bin/env bash
# anonymize.sh — Zookeeper-1434, M4  (revised for METHODOLOGY.md §6 (a)-(e), 2026-08-16).
#
# Deterministically regenerates the two gitignored, LLM-facing artifacts:
#   <BUG_DIR>/source/            curated failure-path sources, anonymized
#   <BUG_DIR>/logs/symptom.log   the DEBUG reproduction log REGENERATED from that source
#
# (a) bug-id scrub          — neither ticket number (the report's own, nor the trunk ticket
#                             that carries the fix) may appear in any LLM-facing artifact.
# (b) distinctive-term      — the CLI command `stat` -> `meta`; the printer
#     rename                  `printStat` -> `printNodeMeta`.
# (c) failure-path file/    — the failure path is one file (it holds the root-cause line and
#     type rename             every frame of the symptom stack trace):
#                             ZooKeeperMain.java / class ZooKeeperMain -> CliShellMain.java /
#                             class CliShellMain, with all references updated (the completor,
#                             bin/zkCli.sh, bin/zkCli.cmd) so the log's frames and the
#                             log4j %C{1} tag carry the neutral name.
# (d) failure-path log-     — every string literal the failure-path file prints is rewritten
#     statement rewrite       to neutral, information-equivalent text: the shell prompt, the
#                             banner/connect lines, the LOG.debug dispatch line, the znode
#                             metadata labels printed by printNodeMeta, and the catch-arm
#                             messages of processCmd.
# (e) regenerate the log    — the anonymized tree is REBUILT and reproduce.sh is re-run
#                             against it, so the log's literals and stack frames match
#                             source/ exactly. The pre-anonymization M3 log is not reused.
#
# Everything else stays real: package paths, the ZooKeeper/ClientCnxn/KeeperException
# classes, the Stat data class, the whole server-side log, and ClientCnxn's per-request
# DEBUG telemetry (none of which is on the failure path).
#
# Run inside the per-bug container:
#   docker run --rm -v "$PWD:/work" --entrypoint bash clods-eval:Zookeeper-Zookeeper-1434 \
#       -lc 'bash /work/evaluations/Zookeeper/Zookeeper-1434/private/anonymize.sh'
set -euo pipefail

BUG_DIR="${BUG_DIR:-/work/evaluations/Zookeeper/Zookeeper-1434}"
REPO="${REPO:-/work/repos/Zookeeper-Zookeeper-1434}"          # pre-fix build tree (M2)
ANON_REPO="${ANON_REPO:-/work/repos/zookeeper-anonymized}"    # neutral path, no bug id

ORIG_CLASS=ZooKeeperMain
ANON_CLASS=CliShellMain
PKG_DIR=src/java/main/org/apache/zookeeper

# ---- 1. copy the pre-fix working tree (incl. deps-fix) to the neutral path -------------
rm -rf "$ANON_REPO"
mkdir -p "$ANON_REPO"
tar -C "$REPO" --exclude=.git --exclude=build -cf - . | tar -C "$ANON_REPO" -xf -

# ---- 2c. failure-path file/type rename --------------------------------------------------
mv "$ANON_REPO/$PKG_DIR/$ORIG_CLASS.java" "$ANON_REPO/$PKG_DIR/$ANON_CLASS.java"
grep -rl "\b$ORIG_CLASS\b" "$ANON_REPO/src/java/main" "$ANON_REPO/bin" \
    | xargs sed -i "s/\b$ORIG_CLASS\b/$ANON_CLASS/g"

MAIN_JAVA="$ANON_REPO/$PKG_DIR/$ANON_CLASS.java"

# ---- 2b. distinctive-term rename --------------------------------------------------------
sed -i \
    -e 's/\bprintStat\b/printNodeMeta/g' \
    -e 's/commandMap\.put("stat"/commandMap.put("meta"/' \
    -e 's/cmd\.equals("stat")/cmd.equals("meta")/' \
    "$MAIN_JAVA"

# ---- 2d. failure-path log-statement rewrite ---------------------------------------------
# Neutral, plausible, information-equivalent wording for every literal this file prints.
sed -i \
    -e 's/"\[zk: "/"[client: "/' \
    -e 's/"Connecting to "/"Contacting server "/' \
    -e 's/"Welcome to ZooKeeper!"/"Interactive client ready."/' \
    -e 's/"JLine support is enabled"/"Line editing enabled."/' \
    -e 's/"JLine support is disabled"/"Line editing unavailable."/' \
    -e 's/"ZooKeeper -server host:port cmd args"/"client -server host:port cmd args"/' \
    -e 's/LOG\.debug("Processing " + cmd)/LOG.debug("Dispatching command: " + cmd)/' \
    -e 's/"cZxid = 0x"/"createTxnId = 0x"/' \
    -e 's/"ctime = "/"createTime = "/' \
    -e 's/"mZxid = 0x"/"modifyTxnId = 0x"/' \
    -e 's/"mtime = "/"modifyTime = "/' \
    -e 's/"pZxid = 0x"/"childTxnId = 0x"/' \
    -e 's/"cversion = "/"childVersion = "/' \
    -e 's/"dataVersion = "/"contentVersion = "/' \
    -e 's/"aclVersion = "/"permVersion = "/' \
    -e 's/"ephemeralOwner = 0x"/"sessionOwner = 0x"/' \
    -e 's/"dataLength = "/"contentLength = "/' \
    -e 's/"numChildren = "/"childCount = "/' \
    -e 's/"Command failed: "/"Command rejected: "/' \
    -e 's/"Node does not exist: "/"No such node: "/' \
    -e 's/"Ephemerals cannot have children: "/"Ephemeral node cannot have children: "/' \
    -e 's/"Node already exists: "/"Node is already present: "/' \
    -e 's/"Node not empty: "/"Node still has children: "/' \
    -e 's/"Created "/"Added node "/' \
    -e 's/"Quitting\.\.\."/"Exiting shell..."/' \
    "$MAIN_JAVA"

# fail fast if any rename/rewrite silently missed
for pat in 'printStat' '"stat"' '"\[zk: "' 'Welcome to ZooKeeper' 'cZxid' 'Node does not exist' 'LOG.debug("Processing '; do
    if grep -qF "$pat" "$MAIN_JAVA"; then echo "anonymization missed: $pat" >&2; exit 1; fi
done
if grep -rqw "$ORIG_CLASS" "$ANON_REPO/src/java/main" "$ANON_REPO/bin"; then
    echo "anonymization missed: $ORIG_CLASS reference" >&2; exit 1
fi

# ---- 3. rebuild the anonymized tree ------------------------------------------------------
( cd "$ANON_REPO" && ant jar )

# ---- 4e. re-run the reproduction against the anonymized build ---------------------------
REPO="$ANON_REPO" BUG_DIR="$BUG_DIR" STAT_CMD=meta PORT="${PORT:-21812}" \
    MAIN_CLASS="org.apache.zookeeper.$ANON_CLASS" NONODE_MSG="No such node:" \
    bash "$BUG_DIR/reproduce.sh"

# ---- 5. publish the log -----------------------------------------------------------------
mkdir -p "$BUG_DIR/logs"
cp "$BUG_DIR/private/symptom.orig.log" "$BUG_DIR/logs/symptom.log"

# ---- 6. publish the curated failure-path sources ----------------------------------------
SRC="$BUG_DIR/source"
rm -rf "$SRC"; mkdir -p "$SRC"
FILES="
$PKG_DIR/$ANON_CLASS.java
$PKG_DIR/ZooKeeper.java
$PKG_DIR/ClientCnxn.java
$PKG_DIR/KeeperException.java
$PKG_DIR/JLineZNodeCompletor.java
$PKG_DIR/ZooDefs.java
$PKG_DIR/Watcher.java
$PKG_DIR/Quotas.java
$PKG_DIR/StatsTrack.java
$PKG_DIR/AsyncCallback.java
src/java/generated/org/apache/zookeeper/data/Stat.java
src/java/generated/org/apache/zookeeper/data/ACL.java
src/java/generated/org/apache/zookeeper/data/Id.java
src/java/generated/org/apache/zookeeper/proto/ExistsRequest.java
src/java/generated/org/apache/zookeeper/proto/SetDataRequest.java
src/java/generated/org/apache/zookeeper/proto/ReplyHeader.java
"
for f in $FILES; do
    mkdir -p "$SRC/$(dirname "$f")"
    cp "$ANON_REPO/$f" "$SRC/$f"
done

# ---- 7. verification (METHODOLOGY §6) ---------------------------------------------------
LOGF="$BUG_DIR/logs/symptom.log"
SYMF="$BUG_DIR/symptom.md"
rc=0
check() {  # check <label> <grep-args...>: any hit is a leak
    label="$1"; shift
    if grep -RnE "$@" 2>/dev/null | head -3 | grep -q .; then
        echo "LEAK ($label):" >&2; grep -RnE "$@" 2>/dev/null | head -3 >&2; rc=1
    fi
}
check "bug id"            'ZOOKEEPER-(1434|1059)|\b1434\b|\b1059\b' "$SRC" "$LOGF" ${SYMF:+"$SYMF"}
check "orig class name"   "\b$ORIG_CLASS\b"                          "$SRC" "$LOGF"
check "printStat"         '\bprintStat\b'                            "$SRC" "$LOGF"
check "orig command"      '(^|[^A-Za-z])stat (/|\[)'                 "$LOGF"
# (d) applies to the log printing statements OF THE FAILURE-PATH FILE and to the log they
# produce. Generic API javadoc elsewhere (e.g. KeeperException's "/** Node does not exist */"
# doc comment on the NONODE code) is not a log literal and is deliberately not touched.
check "orig log literals" 'cZxid|Welcome to ZooKeeper|Node does not exist|\[zk: |JLine support' \
      "$LOGF" "$SRC/$PKG_DIR/$ANON_CLASS.java"
[ $rc -eq 0 ] && echo "[anonymize] OK: source/ + logs/symptom.log regenerated from the anonymized tree, no leakage."
exit $rc
