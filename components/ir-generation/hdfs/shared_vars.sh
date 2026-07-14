#!/usr/bin/env bash
set -euo pipefail

DOCKER_USER="${DOCKER_USER:-${USER}}"
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-${USER}-ir-generation-android}"
# The base image ID recorded on the original build host. Docker image IDs are
# not bit-identical across machines even from the same pinned Dockerfile, so
# this pin is OPTIONAL: leave it empty to only check that the base image exists,
# or set it to a sha256:... ID to enforce a specific verified base.
BASE_IMAGE_ID="${BASE_IMAGE_ID:-}"
IMAGE_NAME="${HDFS_IMAGE_NAME:-${USER}-ir-generation-hdfs}"
CONTAINER_NAME="${HDFS_CONTAINER_NAME:-${USER}-ir-generation-hdfs}"
HADOOP_SOURCE="${HADOOP_SOURCE:-/home/ycx/research/bug/MotivatingExample}"
HADOOP_COMMIT="${HADOOP_COMMIT:-a4c88298d2439782b49b53e470c03a96e24773d6}"
HADOOP_VERSION="${HADOOP_VERSION:-2.7.1}"
# Optional historical reference bitcode for the comparison table. If the file
# exists at run time it is mounted read-only and its symbol counts are compared
# against the freshly produced monolithic bitcode. Leave unset to skip.
HADOOP_REFERENCE_BC="${HADOOP_REFERENCE_BC:-/home/ycx/research/BlameMaster/StaticAnalyisLLVM/bytecode/614good.bc}"
OUTPUT_NAME="hadoop-${HADOOP_VERSION}-${HADOOP_COMMIT:0:8}"
MYUID="$(id -u)"
MYGID="$(id -g)"