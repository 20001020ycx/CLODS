#!/usr/bin/env bash
# reproduce.sh — HDFS-14135  (build step; the reproduction driver is appended at M3)
set -euo pipefail

REPO="${REPO:-/work/repos/HDFS-HDFS-14135}"
BUG_DIR="${BUG_DIR:-/work/evaluations/HDFS/HDFS-14135}"

# ---- build the pre-fix tree from source (idempotent) ----------------------------------
# Requires the per-bug image clods-eval:HDFS-HDFS-14135 (protoc 2.5.0; see private/Dockerfile).
build() {
    cd "$REPO"
    if [ ! -f hadoop-hdfs-project/hadoop-hdfs/target/hadoop-hdfs-3.3.0-SNAPSHOT-tests.jar ]; then
        mvn -pl hadoop-hdfs-project/hadoop-hdfs -am package \
            -DskipTests -DskipITs -Dcheckstyle.skip -Drat.skip -Dmaven.javadoc.skip=true
    fi
}

build
