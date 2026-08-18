#!/usr/bin/env bash
# Repeatedly run the WebHDFS timeout suite; report per-iteration verdicts.
R=/work/repos/HDFS-HDFS-14135
B=/work/evaluations/HDFS/HDFS-14135
N="${N:-10}"
OUT="${OUT:-/tmp/iters}"
mkdir -p "$OUT"
CP="$R/hadoop-hdfs-project/hadoop-hdfs/target/test-classes:$R/hadoop-hdfs-project/hadoop-hdfs/target/classes:$B/private/repro:$(cat $R/cp-test.txt)"
fails=0
for i in $(seq 1 "$N"); do
  java -cp "$CP" -Dlog4j.configuration=file:$B/private/repro/log4j-repro.properties \
    -Dhadoop.log.dir=/tmp -Dtest.build.data=/tmp/tbd \
    org.junit.runner.JUnitCore org.apache.hadoop.hdfs.web.TestWebHdfsTimeouts > "$OUT/it_$i.log" 2>&1
  rc=$?
  verdict=$(grep -m1 -E '^OK \(|^Tests run:' "$OUT/it_$i.log")
  echo "iter=$i rc=$rc $verdict"
  [ "$rc" -ne 0 ] && fails=$((fails+1))
done
echo "total_failed_iterations=$fails / $N"
