#!/usr/bin/env bash
# HBase-3403 — M4 anonymization (METHODOLOGY.md §5/M4 + §6).
#
# Runs on the HOST from the repo root.  Produces, deterministically:
#   repos/HBase-3403-anon/         the pre-fix tree with the failure path renamed/rewritten
#   evaluations/.../source/        that tree's src/main/java (what the LLM reads)
#   evaluations/.../logs/repro.log the standalone reproduction log, regenerated from it
#   evaluations/.../logs/symptom.log  that log merged into the shared production log
#
#   bash evaluations/HBase/HBase-3403/private/anonymize.sh
#
# What is changed and why (§6):
#   (a) bug-id scrub      — "HBASE-3403"/"3403" appear nowhere in the tree or either log
#                           (verified below; they are absent from the pre-fix tree already).
#   (b) distinctive terms — the method names that *name* this bug's mechanism.
#   (c) failure-path file/type renames — the distinctive classes on the causal chain from the
#       root cause (the catalog edit that commits a split) to the symptom (the consistency
#       report).  Generic classes on the chain (SplitTransaction, AssignmentManager,
#       ServerManager, HRegionInfo, HBaseFsck) keep their names: they are HBase's ordinary
#       vocabulary, they appear verbatim in the shared production log, and renaming them
#       would only make the log unreadable without hiding the case.
#   (d) failure-path log-statement rewrites — every log literal emitted by the renamed classes,
#       plus the consistency-checker lines that surface the symptom (these are the strings the
#       JIRA report itself quotes).  SplitTransaction's own literals are deliberately left
#       alone: HBase 1.2.7 emits the identical strings all over the shared production log, so
#       rewriting them in the reproduction would make the reproduction stand out rather than
#       blend in.
set -euo pipefail

ROOT=/mnt/SSD-4T/ycx/CLODS
BUG_DIR="$ROOT/evaluations/HBase/HBase-3403"
SRC_REPO="$ROOT/repos/HBase-HBase-3403"
ANON_REPO="$ROOT/repos/HBase-3403-anon"
PROD_LOG="$ROOT/production-logs/HBase/production.log"
IMAGE=clods-eval:HBase-HBase-3403

cd "$ROOT"

# ---- 1. fresh copy of the pre-fix tree (build fixes + repro test included) ---------------
echo "[anon] copying $SRC_REPO -> $ANON_REPO"
# A previous run's target/ is root-owned (the container writes it), so clear it as root.
docker run --rm -v "$ROOT/repos:/r" --entrypoint bash "$IMAGE" -lc "rm -rf /r/$(basename "$ANON_REPO")"
rm -rf "$ANON_REPO"
mkdir -p "$ANON_REPO"
tar -C "$SRC_REPO" --exclude=.git --exclude=target -cf - . | tar -C "$ANON_REPO" -xf -

cd "$ANON_REPO"

# ---- 2. file/type renames (c) ------------------------------------------------------------
mv src/main/java/org/apache/hadoop/hbase/catalog/MetaEditor.java \
   src/main/java/org/apache/hadoop/hbase/catalog/CatalogWriter.java
mv src/main/java/org/apache/hadoop/hbase/catalog/MetaReader.java \
   src/main/java/org/apache/hadoop/hbase/catalog/CatalogScanner.java
mv src/main/java/org/apache/hadoop/hbase/master/handler/ServerShutdownHandler.java \
   src/main/java/org/apache/hadoop/hbase/master/handler/LostServerHandler.java
mv src/main/java/org/apache/hadoop/hbase/master/handler/MetaServerShutdownHandler.java \
   src/main/java/org/apache/hadoop/hbase/master/handler/MetaLostServerHandler.java
mv src/test/java/org/apache/hadoop/hbase/util/TestSplitCrashRecovery.java \
   src/test/java/org/apache/hadoop/hbase/util/TestClusterWorkload.java
# tests of the renamed classes (not shipped to the LLM, but the tree must still compile)
mv src/test/java/org/apache/hadoop/hbase/catalog/TestMetaReaderEditor.java \
   src/test/java/org/apache/hadoop/hbase/catalog/TestCatalogReaderWriter.java 2>/dev/null || true

# Identifier rewrite across every source file.  Longest first so that
# MetaServerShutdownHandler is handled before ServerShutdownHandler and
# fixupDaughters before fixupDaughter.
FILES=$(find src -name '*.java' -o -name '*.jsp' -o -name '*.rb')
sed -i \
  -e 's/\bMetaServerShutdownHandler\b/MetaLostServerHandler/g' \
  -e 's/\bServerShutdownHandler\b/LostServerHandler/g' \
  -e 's/\bMetaEditor\b/CatalogWriter/g' \
  -e 's/\bMetaReader\b/CatalogScanner/g' \
  -e 's/\bTestMetaReaderEditor\b/TestCatalogReaderWriter/g' \
  -e 's/\bTestSplitCrashRecovery\b/TestClusterWorkload/g' \
  -e 's/\btestDaughterAfterServerCrash\b/testRegionWorkload/g' \
  -e 's/\bofflineParentInMeta\b/offlineSplitParent/g' \
  -e 's/\bfixupDaughters\b/recoverSplitChildren/g' \
  -e 's/\bfixupDaughter\b/recoverSplitChild/g' \
  -e 's/\baddDaughter\b/addSplitChild/g' \
  -e 's/\bgetServerUserRegions\b/getRegionsOfServer/g' \
  -e 's/\bprocessDeadRegion\b/processLostRegion/g' \
  $FILES

# ---- 3. log-statement rewrites (d) -------------------------------------------------------
python3 - <<'PY'
import io, sys

def rewrite(path, pairs):
    s = io.open(path, encoding="utf-8").read()
    for old, new in pairs:
        if old not in s:
            sys.exit("MISSING literal in %s:\n  %r" % (path, old))
        s = s.replace(old, new)
    io.open(path, "w", encoding="utf-8").write(s)
    print("[anon] rewrote %d literals in %s" % (len(pairs), path))

rewrite("src/main/java/org/apache/hadoop/hbase/catalog/CatalogWriter.java", [
    ('"Added region " + regionInfo.getRegionNameAsString() + " to META"',
     '"Recorded region " + regionInfo.getRegionNameAsString() + " in the catalog"'),
    ('"Offlined parent region " + parent.getRegionNameAsString() +\n      " in META"',
     '"Took split parent " + parent.getRegionNameAsString() +\n      " out of service in the catalog"'),
    ('"Added daughter " + regionInfo.getRegionNameAsString() +',
     '"Recorded split child " + regionInfo.getRegionNameAsString() +'),
    ('"Updated row " + regionInfo.getRegionNameAsString() +',
     '"Refreshed catalog row " + regionInfo.getRegionNameAsString() +'),
    ('"Deleted region " + regionInfo.getRegionNameAsString() + " from META"',
     '"Dropped region " + regionInfo.getRegionNameAsString() + " from the catalog"'),
    ('"Deleted daughter reference " + daughter.getRegionNameAsString() +',
     '"Dropped split-child pointer " + daughter.getRegionNameAsString() +'),
    ('"Updated region " + regionInfo.getRegionNameAsString() + " in META"',
     '"Refreshed region " + regionInfo.getRegionNameAsString() + " in the catalog"'),
])

rewrite("src/main/java/org/apache/hadoop/hbase/master/handler/LostServerHandler.java", [
    ('" is NOT in deadservers; it should be!"',
     '" is missing from the lost-server list; it should be there!"'),
    ('"Splitting logs for " + serverName',
     '"Recovering write-ahead logs of " + serverName'),
    ('"Received exception accessing META during server shutdown of " +\n            serverName + ", retrying META read"',
     '"Catalog read failed while recovering " +\n            serverName + ", will try the catalog again"'),
    ('"Removed " + rit.getRegion().getRegionNameAsString() +\n          " from list of regions to assign because in RIT"',
     '"Dropping " + rit.getRegion().getRegionNameAsString() +\n          " from the re-host list; it is already mid-transition"'),
    ('"Reassigning " + hris.size() + " region(s) that " + serverName +\n      " was carrying (skipping " + regionsInTransition.size() +\n      " regions(s) that are already in transition)"',
     '"Re-hosting " + hris.size() + " region(s) last served by " + serverName +\n      " (" + regionsInTransition.size() +\n      " already mid-transition, left alone)"'),
    ('"Finished processing of shutdown of " + serverName',
     '"Completed recovery of " + serverName'),
    ('"Offlined and split region " + hri.getRegionNameAsString() +\n        "; checking daughter presence"',
     '"Region " + hri.getRegionNameAsString() +\n        " is an out-of-service split parent; verifying its children are recorded"'),
    ('"Fixup; missing daughter " + hri.getEncodedName()',
     '"Repairing; unrecorded split child " + hri.getEncodedName()'),
    ('"Daughter " + hri.getRegionNameAsString() + " present"',
     '"Split child " + hri.getRegionNameAsString() + " already recorded"'),
])

# The consistency checker is HBase's shipped operator tool and keeps its name; only the
# literals it prints -- the ones the JIRA report quotes -- are rewritten.
rewrite("src/main/java/org/apache/hadoop/hbase/util/HBaseFsck.java", [
    ('"Region " + descriptiveName + " offline, split, parent, ignoring."',
     '"Region " + descriptiveName + " is an out-of-service split parent; skipping."'),
    ('"Region " + descriptiveName + " on HDFS, but not listed in META " +\n        "or deployed on any region server."',
     '"Region " + descriptiveName + " has a directory on HDFS with no catalog row, " +\n        "and no region server is serving it."'),
    ('"Found inconsistency in table " + tInfo.getName()',
     '"Consistency check failed for table " + tInfo.getName()'),
    ('System.out.println("Table " + tInfo.getName() + " is inconsistent.");',
     'System.out.println("Table " + tInfo.getName() + " did not pass the consistency check.");'),
    ('System.out.println(Integer.toString(errorCount) +\n                         " inconsistencies detected.");',
     'System.out.println(Integer.toString(errorCount) +\n                         " problem(s) detected.");'),
    ('System.out.println("Status: INCONSISTENT");',
     'System.out.println("Status: FAILED");'),
])
PY

# ---- 4. rebuild + reproduce from the anonymized tree (§6 (e)) ----------------------------
echo "[anon] rebuilding and re-reproducing from the anonymized tree"
rm -f "$BUG_DIR/logs/repro.log"
# The anonymized tree and the maven local repository are bind-mounted at the NEUTRAL container
# paths /src and /m2.  Every path the JVM records in its own log (user.dir, java.class.path,
# hbase.rootdir, HDFS storage dirs) then reads /src/... and /m2/..., so the bug id cannot leak
# into the LLM-facing log through a directory name -- while the host keeps its per-bug
# directory names, so no other agent's workspace is touched.
docker run --rm -v "$ROOT:/work" -v "$ANON_REPO:/src" -v "$ROOT/repos/m2-HBase-3403:/m2" \
  --entrypoint bash "$IMAGE" -lc \
  "SRC=/src SETTINGS=/m2/settings.anon.xml \
   OUT_LOG=/work/evaluations/HBase/HBase-3403/logs/repro.log \
   TEST=TestClusterWorkload bash /work/evaluations/HBase/HBase-3403/reproduce.sh" \
  && rc=0 || rc=$?
# reproduce.sh exits non-zero because the test asserts and fails -- that IS the reproduction.
echo "[anon] reproduce.sh exit=$rc (non-zero expected: the assertion fires)"
test -s "$BUG_DIR/logs/repro.log" || { echo "[anon] FATAL: no reproduction log"; exit 1; }
grep -q "has a directory on HDFS with no catalog row" "$BUG_DIR/logs/repro.log" \
  || { echo "[anon] FATAL: the anonymized build no longer reproduces the symptom"; exit 1; }

# ---- 5. source/ = the anonymized main tree ----------------------------------------------
rm -rf "$BUG_DIR/source"
mkdir -p "$BUG_DIR/source/src/main"
cp -a "$ANON_REPO/src/main/java" "$BUG_DIR/source/src/main/java"

# ---- 6. merged, LLM-facing log ----------------------------------------------------------
# No --rename: none of the renamed identifiers or rewritten literals occur in the shared
# production log (verified in step 7), so the production stream needs no substitution and is
# copied through byte-for-byte.
python3 "$BUG_DIR/private/merge_logs.py" \
    --production "$PROD_LOG" \
    --repro      "$BUG_DIR/logs/repro.log" \
    --out        "$BUG_DIR/logs/symptom.log" \
    --interleave position

# ---- 7. leakage verification (§6 "Verification") ----------------------------------------
# Kept in its own script: every grep here is expected to find nothing, and `set -e` in this
# script would abort on grep's exit status 1.
bash "$BUG_DIR/private/verify_anon.sh"
