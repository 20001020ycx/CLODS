#!/usr/bin/env bash
# HBase-4078 — M4 anonymization (METHODOLOGY §6). Runs inside the per-bug container:
#   docker run --rm -v /mnt/SSD-4T/ycx/CLODS:/work -v hbase4078-m2:/root/.m2 \
#     --entrypoint bash clods-eval:HBase-HBase-4078 \
#     /work/evaluations/HBase/HBase-4078/private/anonymize.sh
#
# Deterministic replay: pre-fix tree (already carrying private/deps-fix.patch) -> one
# longest-key-first substitution pass driven by private/anonymization_map.json -> file
# renames so each renamed public type still lives in its own file -> rebuild -> copy the
# failure-path files into source/. The reproduction is then re-run against this tree
# (reproduce.sh with SRC_DIR pointing here) so both logs come from the anonymized build.
set -uo pipefail

BUG_DIR=/work/evaluations/HBase/HBase-4078
PRE=/work/repos/HBase-HBase-4078
ANON=${ANON_DIR:-/work/repos/hbase4078-anon}
MAP=$BUG_DIR/private/anonymization_map.json
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export PATH=$JAVA_HOME/bin:$PATH

say() { echo; echo "=== $* ==="; }
die() { echo "FATAL: $*" >&2; exit 1; }

say "1. copy the pre-fix tree to $ANON"
[ -d "$PRE/src/main/java" ] || die "no pre-fix tree at $PRE"
rm -rf "$ANON"; mkdir -p "$ANON"
(cd "$PRE" && tar cf - --exclude=./target --exclude=./.git .) | (cd "$ANON" && tar xf -)

say "2. apply the anonymization map (one longest-key-first pass over src/main/java)"
python3 - "$MAP" "$ANON" <<'PY'
import json, os, re, sys
mapfile, root = sys.argv[1], sys.argv[2]
m = json.load(open(mapfile))

subs = {}   # original -> (anonymized, word_boundary?)
for e in m.get("b_distinctive_term_renames", []):
    subs[e["original"]] = (e["anonymized"], True)
for e in m["c_failure_path_type_renames"]["renames"]:
    subs[e["original"]] = (e["anonymized"], True)
for e in m["d_failure_path_log_statement_rewrites"]["rewrites"]:
    subs[e["original"]] = (e["anonymized"], False)

keys = sorted(subs, key=len, reverse=True)
parts = []
for k in keys:
    esc = re.escape(k)
    parts.append(r"\b%s\b" % esc if subs[k][1] else esc)
pat = re.compile("|".join(parts))
def rep(mo):
    return subs[mo.group(0)][0]

src = os.path.join(root, "src", "main", "java")
changed = hits = 0
for dirpath, _dirs, files in os.walk(src):
    for f in files:
        if not f.endswith(".java"):
            continue
        p = os.path.join(dirpath, f)
        s = open(p, encoding="utf-8").read()
        s2, n = pat.subn(rep, s)
        if n:
            open(p, "w", encoding="utf-8").write(s2)
            changed += 1
            hits += n
print("[anon] %d substitutions in %d files" % (hits, changed))

# file name must follow the public type name
for e in m["c_failure_path_type_renames"]["renames"]:
    if not e.get("is_type", True):
        continue
    old, new = e["original"] + ".java", e["anonymized"] + ".java"
    for dirpath, _dirs, files in os.walk(src):
        if old in files:
            os.rename(os.path.join(dirpath, old), os.path.join(dirpath, new))
            print("[anon] renamed %s -> %s" % (old, new))
PY
[ $? -eq 0 ] || die "substitution pass failed"

say "2b. emit the production-stream rename file used by the merge"
python3 - "$MAP" "$BUG_DIR/private/.production-rename.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
json.dump(m["production_log_handling"]["substitutions"], open(sys.argv[2], "w"), indent=2)
print("[anon] wrote", sys.argv[2])
PY

say "3. rebuild the anonymized tree"
# -Dmaven.test.skip=true: the renames are applied to src/main/java only (the LLM never sees
# the test tree), so test sources are not compiled.
# maven-compiler-plugin 2.0.2 cannot parse javac 8's "bootstrap class path not set in
# conjunction with -source 1.6" warning and fails the *first*, whole-tree compile on it; the
# classes are written anyway, so the immediately following incremental compile succeeds. The
# same thing happens on the pre-fix tree at M2. Hence: build, and build again if needed.
for attempt in 1 2; do
  (cd "$ANON" && mvn -B -Dmaven.test.skip=true package 2>&1 | grep -vE "^Progress|Downloa" \
     | tee "$ANON/build.log" | tail -4)
  grep -qF "BUILD SUCCESS" "$ANON/build.log" && break
  echo "  (compile pass $attempt did not report success; retrying)"
done
grep -qF "BUILD SUCCESS" "$ANON/build.log" || grep -E "error:|\.java:\[" "$ANON/build.log" | head -20
[ -f "$ANON/target/hbase-0.93-SNAPSHOT.jar" ] || die "anonymized tree does not build"
mkdir -p "$ANON/target/lib" && cp -a "$PRE/target/lib/." "$ANON/target/lib/"

say "4. populate source/ with the failure-path files (anonymized)"
SRC_OUT=$BUG_DIR/source
rm -rf "$SRC_OUT"; mkdir -p "$SRC_OUT"
while read -r rel; do
  [ -n "$rel" ] || continue
  f="$ANON/src/main/java/$rel"
  [ -f "$f" ] || { echo "  MISSING $rel"; continue; }
  mkdir -p "$SRC_OUT/$(dirname "$rel")"
  cp -a "$f" "$SRC_OUT/$rel"
  echo "  $rel"
done < <(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
for f in m["failure_path_files"]: print(f)
' "$MAP")

say "5. leakage check over source/"
BAD=0
for t in $(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
out=["HBASE-4078","4078"]
out += [e["original"] for e in m["c_failure_path_type_renames"]["renames"] if e.get("is_type",True)]
print(" ".join(out))
' "$MAP"); do
  n=$(grep -rwF -- "$t" "$SRC_OUT" 2>/dev/null | wc -l)
  printf '  %-28s %s\n' "$t" "$n"
  [ "$n" = "0" ] || BAD=1
done
[ "$BAD" = "0" ] && echo "  source/ is clean" || echo "  LEAKAGE — fix the map and re-run"

say "DONE — now re-run the reproduction against $ANON (SRC_DIR=$ANON bash $BUG_DIR/reproduce.sh)"
