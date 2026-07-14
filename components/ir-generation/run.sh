#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_vars.sh
source "${script_dir}/shared_vars.sh"

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container '${CONTAINER_NAME}' already exists." >&2
    echo "Run ./delete.sh first, or set a different CONTAINER_NAME in shared_vars.sh." >&2
    exit 1
fi

docker run \
    --detach \
    --name "${CONTAINER_NAME}" \
    --mount "type=bind,src=${script_dir},dst=/workspace" \
    "${IMAGE_NAME}"

echo "Started ${CONTAINER_NAME}."
echo "Run ./generate-ir.sh for the complete example, or ./attach.sh for a shell."
