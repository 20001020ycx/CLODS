#!/usr/bin/env bash
# M2 dependency fix for HBase-3627 (pre-fix tree = branch-0.90 @ 86e9f5f8c9, 0.90.2-SNAPSHOT).
#
# Why this is needed: the 2011 pom pins three artifacts that no longer exist anywhere on
# the network — org.apache.hadoop:hadoop-core:0.20-append-r1056497 and
# org.apache.hadoop:hadoop-test:0.20-append-r1056497 (a private HBase build of the
# branch-0.20-append Hadoop, never published to Central) and org.apache.hadoop:avro:1.3.3 /
# org.apache.thrift:thrift:0.2.0 (published only to the long-dead people.apache.org and
# repository.codehaus.org repos the pom lists). Rather than change the pinned versions, we
# install the *exact* jars that shipped in the matching Apache release tarball
# (hbase-0.90.2.tar.gz, whose lib/ is precisely this pom's dependency set) into the per-bug
# local Maven repo, so the source build resolves the original versions.
#
# The only substitution is hadoop-test (not shipped in the tarball): Central's
# hadoop-test-0.20.2.jar is installed under the 0.20-append-r1056497 coordinate. It is a
# test-scope dependency (MiniDFSCluster/MiniMRCluster) and is not on the failure path.
#
# Run inside the per-bug container (clods-eval:HBase-HBase-3627), with the repo at /work.
set -euo pipefail

DIST=/work/repos/hbase-dist-3627
LIB=$DIST/hbase-0.90.2/lib
HV=0.20-append-r1056497

if [ ! -d "$LIB" ]; then
  echo "ERROR: $LIB missing — fetch https://archive.apache.org/dist/hbase/hbase-0.90.2/hbase-0.90.2.tar.gz into $DIST and untar hbase-0.90.2/lib" >&2
  exit 1
fi

mvn -q org.apache.maven.plugins:maven-install-plugin:2.5.2:install-file \
  -Dfile="$LIB/hadoop-core-$HV.jar" \
  -DgroupId=org.apache.hadoop -DartifactId=hadoop-core -Dversion=$HV -Dpackaging=jar

mvn -q org.apache.maven.plugins:maven-install-plugin:2.5.2:install-file \
  -Dfile="$DIST/hadoop-test-0.20.2.jar" \
  -DgroupId=org.apache.hadoop -DartifactId=hadoop-test -Dversion=$HV -Dpackaging=jar

mvn -q org.apache.maven.plugins:maven-install-plugin:2.5.2:install-file \
  -Dfile="$LIB/avro-1.3.3.jar" \
  -DgroupId=org.apache.hadoop -DartifactId=avro -Dversion=1.3.3 -Dpackaging=jar

mvn -q org.apache.maven.plugins:maven-install-plugin:2.5.2:install-file \
  -Dfile="$LIB/thrift-0.2.0.jar" \
  -DgroupId=org.apache.thrift -DartifactId=thrift -Dversion=0.2.0 -Dpackaging=jar

echo "install-deps.sh: installed hadoop-core/$HV, hadoop-test/$HV, avro/1.3.3, thrift/0.2.0"
