#!/usr/bin/env bash
set -euo pipefail

export JAVA_HOME=/opt/jvmci
export PATH="/opt/mx:/opt/jvmci/bin:${PATH}"
export GRAAL_HOME=/opt/graal
export GRAAL_LLVM=/opt/graal/sdk/mxbuild/linux-amd64/LLVM_TOOLCHAIN/bin

exec "$@"
