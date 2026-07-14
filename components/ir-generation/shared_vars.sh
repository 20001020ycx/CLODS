#!/usr/bin/env bash
set -euo pipefail

DOCKER_USER="${DOCKER_USER:-${USER}}"
IMAGE_NAME="${IMAGE_NAME:-${USER}-ir-generation-android}"
CONTAINER_NAME="${CONTAINER_NAME:-${USER}-ir-generation-android}"
MYUID="$(id -u)"
MYGID="$(id -g)"
