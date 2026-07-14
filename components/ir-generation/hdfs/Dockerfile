ARG BASE_IMAGE=ycx-ir-generation-android:latest
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG DOCKER_USER=artifact
ARG MAVEN_VERSION=3.6.3
ARG MAVEN_SHA256=26ad91d751b3a9a53087aefa743f4e16a17741d3915b219cf74112bf87a438c5
ARG PROTOBUF_VERSION=2.5.0
ARG PROTOBUF_SHA256=c55aa3dc538e6fd5eaf732f4eb6b98bdcb7cedb5b91d3b5bdcf29c98c293f58e

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        libtool \
        pkg-config \
        rsync \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --retry 5 \
        --output /tmp/apache-maven.tar.gz \
        "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    && printf '%s  %s\n' "${MAVEN_SHA256}" /tmp/apache-maven.tar.gz | sha256sum --check --strict \
    && tar --extract --gzip --file /tmp/apache-maven.tar.gz --directory /opt \
    && ln -s "/opt/apache-maven-${MAVEN_VERSION}" /opt/maven \
    && rm /tmp/apache-maven.tar.gz

RUN curl --fail --location --retry 5 \
        --output /tmp/protobuf.tar.gz \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protobuf-${PROTOBUF_VERSION}.tar.gz" \
    && printf '%s  %s\n' "${PROTOBUF_SHA256}" /tmp/protobuf.tar.gz | sha256sum --check --strict \
    && mkdir -p /tmp/protobuf-src \
    && tar --extract --gzip --file /tmp/protobuf.tar.gz --directory /tmp/protobuf-src --strip-components=1 \
    && cd /tmp/protobuf-src \
    && ./configure --prefix="/opt/protobuf-${PROTOBUF_VERSION}" \
    && make -j"$(nproc)" \
    && make install \
    && ln -s "/opt/protobuf-${PROTOBUF_VERSION}" /opt/protobuf \
    && rm -rf /tmp/protobuf.tar.gz /tmp/protobuf-src

ENV MAVEN_HOME=/opt/maven
ENV HADOOP_PROTOC_PATH=/opt/protobuf/bin/protoc
ENV PATH=/opt/maven/bin:/opt/protobuf/bin:${PATH}

RUN mkdir -p /work \
    && chown "${DOCKER_USER}:${DOCKER_USER}" /work \
    && mvn --version \
    && protoc --version

USER ${DOCKER_USER}
WORKDIR /artifact
CMD ["sleep", "infinity"]
