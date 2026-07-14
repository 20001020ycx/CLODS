#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_vars.sh
source "${script_dir}/shared_vars.sh"

actual_base_id="$(docker image inspect "${BASE_IMAGE_NAME}" --format '{{.Id}}' 2>/dev/null || true)"
if [[ -z "${actual_base_id}" ]]; then
    echo "Base image '${BASE_IMAGE_NAME}' does not exist. Build the top-level SimpleMath image first." >&2
    exit 1
fi
if [[ -n "${BASE_IMAGE_ID}" && "${actual_base_id}" != "${BASE_IMAGE_ID}" ]]; then
    echo "Base image identity mismatch." >&2
    echo "Expected: ${BASE_IMAGE_ID}" >&2
    echo "Actual:   ${actual_base_id}" >&2
    echo "Set BASE_IMAGE_ID deliberately (or clear it in shared_vars.sh) if you have rebuilt and re-verified the base artifact." >&2
    exit 1
fi

docker build \
    --network=host \
    --build-arg "BASE_IMAGE=${BASE_IMAGE_NAME}" \
    --build-arg "DOCKER_USER=${DOCKER_USER}" \
    --tag "${IMAGE_NAME}" \
    --file "${script_dir}/Dockerfile" \
    "${script_dir}"