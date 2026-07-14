#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_vars.sh
source "${script_dir}/shared_vars.sh"

if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container '${CONTAINER_NAME}' does not exist. Run ./run.sh first." >&2
    exit 1
fi
if [[ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")" != "true" ]]; then
    docker start "${CONTAINER_NAME}" >/dev/null
fi

echo "[1/3] Building Hadoop ${HADOOP_VERSION} and staging the NameNode classpath"
docker exec --interactive --user "${DOCKER_USER}" \
    --env "HADOOP_COMMIT=${HADOOP_COMMIT}" \
    --env "HADOOP_VERSION=${HADOOP_VERSION}" \
    --env "HADOOP_SOURCE=${HADOOP_SOURCE}" \
    "${CONTAINER_NAME}" /artifact/container/build-hadoop.sh

echo "[2/3] Compiling NameNode through GraalVM's LLVM backend"
docker exec --interactive --user "${DOCKER_USER}" \
    --env "HADOOP_COMMIT=${HADOOP_COMMIT}" \
    --env "HADOOP_VERSION=${HADOOP_VERSION}" \
    --env "HDFS_NATIVE_IMAGE_MODE=${HDFS_NATIVE_IMAGE_MODE:-compat}" \
    "${CONTAINER_NAME}" /artifact/container/generate-native-image.sh

echo "[3/3] Verifying the executable and LLVM artifacts"
docker exec --interactive --user "${DOCKER_USER}" \
    --env "HADOOP_COMMIT=${HADOOP_COMMIT}" \
    --env "HADOOP_VERSION=${HADOOP_VERSION}" \
    --env "HADOOP_REFERENCE_BC=${HADOOP_REFERENCE_BC}" \
    "${CONTAINER_NAME}" /artifact/container/verify-artifacts.sh

echo
echo "Success. Host-visible HDFS artifacts:"
echo "  output/${OUTPUT_NAME}/namenode/namenode"
echo "  output/${OUTPUT_NAME}/namenode/namenode.monolithic.bc"
echo "  output/${OUTPUT_NAME}/namenode/function2IRmapping.txt"
echo "  output/${OUTPUT_NAME}/namenode/chooseRandom.bc"
echo "  output/${OUTPUT_NAME}/namenode/chooseRandom.ll"
echo "  output/${OUTPUT_NAME}/verification/comparison.txt"