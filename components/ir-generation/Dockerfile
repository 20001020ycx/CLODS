FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive
ARG DOCKER_USER=artifact
ARG UID=1000
ARG GID=1000

ARG GRAAL_COMMIT=ec486f0f2bc598d3212b62a8d05a10b6d07dea92
ARG MX_COMMIT=522b8518dccff250ee036d7f5f87f16deea95455
ARG JVMCI_ARCHIVE=openjdk-8u302+07-jvmci-21.2-b08-linux-amd64.tar.gz
ARG JVMCI_URL=https://github.com/graalvm/graal-jvmci-8/releases/download/jvmci-21.2-b08/openjdk-8u302%2B07-jvmci-21.2-b08-linux-amd64.tar.gz

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash-completion \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        libffi-dev \
        libssl-dev \
        libxml2-dev \
        python3 \
        python3-distutils \
        python-is-python3 \
        unzip \
        wget \
        xz-utils \
        zip \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${GID}" "${DOCKER_USER}" \
    && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash "${DOCKER_USER}" \
    && chown "${DOCKER_USER}:${DOCKER_USER}" /opt

USER ${DOCKER_USER}

RUN git clone --filter=blob:none --no-checkout https://github.com/rishikeshdevsot/graal.git /opt/graal \
    && git -C /opt/graal fetch --depth=1 origin "${GRAAL_COMMIT}" \
    && git -C /opt/graal checkout --detach FETCH_HEAD \
    && test "$(git -C /opt/graal rev-parse HEAD)" = "${GRAAL_COMMIT}" \
    && git clone --filter=blob:none --no-checkout https://github.com/graalvm/mx.git /opt/mx \
    && git -C /opt/mx fetch --depth=1 origin "${MX_COMMIT}" \
    && git -C /opt/mx checkout --detach FETCH_HEAD \
    && test "$(git -C /opt/mx rev-parse HEAD)" = "${MX_COMMIT}"

COPY --chown=${DOCKER_USER}:${DOCKER_USER} android-ir-disable-app-bypass.patch /tmp/android-ir-disable-app-bypass.patch
RUN git -C /opt/graal apply --check /tmp/android-ir-disable-app-bypass.patch \
    && git -C /opt/graal apply /tmp/android-ir-disable-app-bypass.patch \
    && rm /tmp/android-ir-disable-app-bypass.patch

RUN curl --fail --location --retry 5 --output "/tmp/${JVMCI_ARCHIVE}" "${JVMCI_URL}" \
    && mkdir -p /opt/jvmci \
    && tar --extract --gzip --file "/tmp/${JVMCI_ARCHIVE}" --directory /opt/jvmci --strip-components=1 \
    && rm "/tmp/${JVMCI_ARCHIVE}" \
    && /opt/jvmci/bin/java -version

ENV JAVA_HOME=/opt/jvmci
ENV PATH=/opt/mx:/opt/jvmci/bin:${PATH}
ENV GRAAL_HOME=/opt/graal
ENV GRAAL_LLVM=/opt/graal/sdk/mxbuild/linux-amd64/LLVM_TOOLCHAIN/bin

WORKDIR /opt/graal/substratevm

# Build Native Image and the Graal-managed LLVM 14 toolchain from the pinned
# android_IR source revision. The LLVM binaries themselves are downloaded by mx.
RUN mx build --all

USER root
COPY entrypoint.sh /usr/local/bin/ir-entrypoint
RUN chmod 0755 /usr/local/bin/ir-entrypoint \
    && printf '%s\n' '#!/usr/bin/env bash' 'exec "${GRAAL_LLVM}/llvm-dis" "$@"' > /usr/local/bin/gdis \
    && chmod 0755 /usr/local/bin/gdis

USER ${DOCKER_USER}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/ir-entrypoint"]
CMD ["sleep", "infinity"]
