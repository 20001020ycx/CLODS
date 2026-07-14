#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_vars.sh
source "${script_dir}/shared_vars.sh"

docker build \
    --network=host \
    --build-arg "DOCKER_USER=${DOCKER_USER}" \
    --build-arg "UID=${MYUID}" \
    --build-arg "GID=${MYGID}" \
    --tag "${IMAGE_NAME}" \
    --file "${script_dir}/Dockerfile" \
    "${script_dir}"
