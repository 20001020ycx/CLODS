#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_vars.sh
source "${script_dir}/shared_vars.sh"

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    docker rm --force "${CONTAINER_NAME}"
else
    echo "Container '${CONTAINER_NAME}' does not exist; nothing to delete."
fi
