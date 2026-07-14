#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_vars.sh
source "${script_dir}/shared_vars.sh"

if [[ ! -d "${HADOOP_SOURCE}/.git" ]]; then
    echo "Hadoop source '${HADOOP_SOURCE}' is not a Git checkout." >&2
    exit 1
fi

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container '${CONTAINER_NAME}' already exists." >&2
    echo "Run ./delete.sh first, or set HDFS_CONTAINER_NAME." >&2
    exit 1
fi

mounts=(
    --mount "type=bind,src=${script_dir},dst=/artifact"
    --mount "type=bind,src=${HADOOP_SOURCE},dst=/input/hadoop,readonly"
    --mount "type=volume,src=${CONTAINER_NAME}-work,dst=/work"
)
envs=(
    --env "HADOOP_SOURCE=${HADOOP_SOURCE}"
    --env "HADOOP_COMMIT=${HADOOP_COMMIT}"
    --env "HADOOP_VERSION=${HADOOP_VERSION}"
)
if [[ -n "${HADOOP_REFERENCE_BC}" && -f "${HADOOP_REFERENCE_BC}" ]]; then
    mounts+=(
        --mount "type=bind,src=${HADOOP_REFERENCE_BC},dst=/input/reference.bc,readonly"
    )
    envs+=(--env "HADOOP_REFERENCE_BC=${HADOOP_REFERENCE_BC}")
    reference_note="  Reference bitcode mounted read-only at /input/reference.bc for the comparison table."
else
    reference_note="  Reference bitcode not found at '${HADOOP_REFERENCE_BC}'; the comparison table will be skipped."
fi

docker run \
    --detach \
    --name "${CONTAINER_NAME}" \
    "${envs[@]}" \
    "${mounts[@]}" \
    "${IMAGE_NAME}"

echo "Started ${CONTAINER_NAME}."
echo "The authoritative Hadoop checkout is mounted read-only at /input/hadoop."
echo "${reference_note}"
echo "Run ./generate-hdfs-ir.sh to build Hadoop and generate NameNode LLVM IR."