# CLODS LLM-diagnosis evaluation image.
# Provides the toolchain to clone/build/reproduce the studied systems and to run the
# 5x network-locked diagnosis. The agent runs on the host and launches this image for
# per-bug build/reproduce/diagnose steps — never build or diagnose on bare metal.
# See context/README.md (operator walkthrough) and context/METHODOLOGY.md §11 (usage).

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    MAVEN_OPTS="-Xmx4g" \
    GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx4g"

# ---- Core toolchain -------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        git git-lfs openssh-client \
        build-essential autoconf automake libtool pkg-config cmake ninja-build \
        python3 python3-pip python3-venv \
        jq ripgrep less file zip unzip tar \
        iptables iproute2 iputils-ping dnsutils \
        default-jdk maven gradle \
    && rm -rf /var/lib/apt/lists/*

# Node.js (for the Claude Code CLI) and the CLI itself.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# ---- Evaluation harness ---------------------------------------------------
RUN mkdir -p /opt/clods /work
COPY context/run_diagnosis.sh /opt/clods/run_diagnosis.sh
RUN chmod +x /opt/clods/run_diagnosis.sh

WORKDIR /work
# Default: drop into a shell for the setup phase (M0-M5). The diagnosis phase
# overrides --entrypoint to run_diagnosis.sh with the network locked.
ENTRYPOINT ["/bin/bash"]