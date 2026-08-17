#!/usr/bin/env bash
# M4 for HBase-3627 (METHODOLOGY §5/M4 + §6): anonymize the failure path, rebuild, re-run the
# reproduction against the anonymized binaries, and re-merge into the shared production log.
#
#   bash private/anonymize.sh          # run INSIDE the per-bug container (--cpus=2), repo at /work
#
# What it does
#   1. builds a fresh copy of the pre-fix tree at $ANON_REPO (pre_fix_commit + deps-fix.patch);
#   2. applies private/anon-map-source.json in ONE longest-key-first pass to every .java/.jsp
#      file — this both renames the failure-path types and rewrites the failure-path log
#      literals — then renames the files whose public type changed;
#   3. rebuilds ('mvn -DskipTests package') and re-runs reproduce.sh against the anonymized
#      tree, so logs/repro.log is written by the anonymized binaries (Log A);
#   4. merges Log A into production-logs/HBase/production.log with the same map applied to the
#      production stream (private/anon-map-production.json) -> logs/symptom.log (Log B);
#   5. copies the anonymized src/main/java into source/;
#   6. verifies that no original failure-path identifier, JIRA-quoted literal or bug id
#      survives in source/, logs/repro.log or the whole merged logs/symptom.log.
set -euo pipefail

BUG_DIR=${BUG_DIR:-/work/evaluations/HBase/HBase-3627}
SRC_REPO=${SRC_REPO:-/work/repos/HBase-HBase-3627}
ANON_REPO=${ANON_REPO:-/work/repos/hbase-anon-3627}
PROD_LOG=${PROD_LOG:-/work/production-logs/HBase/production.log}
SMAP=$BUG_DIR/private/anon-map-source.json
PMAP=$BUG_DIR/private/anon-map-production.json
PRE_FIX=86e9f5f8c9cb36b3dd2a1344c8c8c2bf95f44cc5

echo "[anonymize] 1/6 fresh pre-fix tree -> $ANON_REPO"
rm -rf "$ANON_REPO"; mkdir -p "$ANON_REPO"
git -C "$SRC_REPO" archive "$PRE_FIX" | tar -x -C "$ANON_REPO"
git -C "$ANON_REPO" init -q 2>/dev/null || true
patch -p1 -d "$ANON_REPO" -s < "$BUG_DIR/private/deps-fix.patch"

echo "[anonymize] 2/6 applying the rename + log-rewrite map"
python3 - "$ANON_REPO" "$SMAP" <<'PY'
import json, os, re, sys
root, mapfile = sys.argv[1], sys.argv[2]
m = json.load(open(mapfile))
pat = re.compile("|".join(re.escape(k) for k in sorted(m, key=len, reverse=True)))
changed = files = 0
for dirpath, _dirs, names in os.walk(os.path.join(root, "src")):
    for n in names:
        if not n.endswith((".java", ".jsp", ".xml", ".rb")):
            continue
        p = os.path.join(dirpath, n)
        s = open(p, encoding="utf-8", errors="surrogateescape").read()
        t = pat.sub(lambda x: m[x.group(0)], s)
        files += 1
        if t != s:
            open(p, "w", encoding="utf-8", errors="surrogateescape").write(t)
            changed += 1
print(f"[anonymize]   substituted in {changed}/{files} files")
# rename the files whose public type was renamed
renames = {
    "src/main/java/org/apache/hadoop/hbase/zookeeper/ZKAssign.java": "RegionStateZK.java",
    "src/main/java/org/apache/hadoop/hbase/zookeeper/ZKUtil.java": "ZKOps.java",
    "src/main/java/org/apache/hadoop/hbase/executor/RegionTransitionData.java": "RegionStateRecord.java",
    "src/main/java/org/apache/hadoop/hbase/executor/EventHandler.java": "TaskHandler.java",
    "src/main/java/org/apache/hadoop/hbase/util/Writables.java": "SerdeUtil.java",
    "src/main/java/org/apache/hadoop/hbase/regionserver/handler/OpenRegionHandler.java": "RegionBringupHandler.java",
    "src/main/java/org/apache/hadoop/hbase/master/AssignmentManager.java": "RegionPlacementManager.java",
    "src/main/java/org/apache/hadoop/hbase/master/handler/OpenedRegionHandler.java": "RegionOnlineHandler.java",
}
for old, new in renames.items():
    src = os.path.join(root, old)
    dst = os.path.join(os.path.dirname(src), new)
    if os.path.exists(src):
        os.rename(src, dst)
        print(f"[anonymize]   {os.path.basename(old)} -> {new}")
    elif not os.path.exists(dst):
        sys.exit(f"[anonymize] FATAL: neither {src} nor {dst} exists")
# the test that names the handler class in its file name follows too
for dirpath, _dirs, names in os.walk(os.path.join(root, "src/test")):
    for n in names:
        if "OpenRegionHandler" in n or "AssignmentManager" in n or "ZKAssign" in n:
            os.rename(os.path.join(dirpath, n),
                      os.path.join(dirpath, n.replace("OpenRegionHandler", "RegionBringupHandler")
                                             .replace("AssignmentManager", "RegionPlacementManager")
                                             .replace("ZKAssign", "RegionStateZK")))
PY

echo "[anonymize] 3/6 rebuilding the anonymized tree"
( cd "$ANON_REPO" && mvn -q -DskipTests -Dmaven.javadoc.skip=true package ) \
  || { echo "[anonymize] FATAL: anonymized tree does not compile"; exit 1; }

echo "[anonymize] 4/6 re-running the reproduction against the anonymized binaries"
rc=0
bash "$BUG_DIR/reproduce.sh" "$ANON_REPO" /work/repos/hbase-run-3627 "$BUG_DIR/logs/repro.log" || rc=$?
[ "$rc" -eq 0 ] || { echo "[anonymize] FATAL: the anonymized build no longer reproduces (rc=$rc)"; exit "$rc"; }

echo "[anonymize] 5/6 merging into the shared production log"
python3 "$BUG_DIR/private/merge_logs.py" \
    --production "$PROD_LOG" \
    --repro      "$BUG_DIR/logs/repro.log" \
    --out        "$BUG_DIR/logs/symptom.log" \
    --interleave position \
    --rename     "$PMAP"

echo "[anonymize] 6/6 source/ + leak check"
rm -rf "$BUG_DIR/source"; mkdir -p "$BUG_DIR/source"
cp -a "$ANON_REPO/src/main/java" "$BUG_DIR/source/java"
echo "[anonymize] source/ = $(find "$BUG_DIR/source" -name '*.java' | wc -l) java files"

bad=0
for pat in 'HBASE-3627' '\b3627\b' '\bZKAssign\b' '\bZKUtil\b' '\bRegionTransitionData\b' \
           '\bWritables\b' '\bEventHandler\b' '\bOpenRegionHandler\b' '\bOpenedRegionHandler\b' \
           '\bAssignmentManager\b' 'M_RS_OPEN_REGION' 'RS_OPEN_REGION' \
           'Caught throwable while processing event' 'Unable to get data of znode' \
           'Attempting to transition node'; do
    hits=""
    for f in "$BUG_DIR/source" "$BUG_DIR/logs/repro.log" "$BUG_DIR/logs/symptom.log" "$BUG_DIR/symptom.md"; do
        [ -e "$f" ] || continue
        c="$(LC_ALL=C grep -rEc -- "$pat" "$f" /dev/null 2>/dev/null | grep -v ':0$' || true)"
        [ -n "$c" ] && hits="$hits $f"
    done
    if [ -n "$hits" ]; then echo "[anonymize] LEAK '$pat' in:$hits"; bad=1; fi
done
[ "$bad" -eq 0 ] && echo "[anonymize] leak check: clean" || { echo "[anonymize] LEAK CHECK FAILED"; exit 1; }
