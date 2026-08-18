FROM clods-eval

# Hadoop 3.3.0-SNAPSHOT (July 2019) requires protoc 2.5.0 exactly; Ubuntu 22.04 ships
# protobuf 3.x, and upstream published no 2.5.0 linux binary, so build it from source.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends g++ make; \
    rm -rf /var/lib/apt/lists/*; \
    cd /tmp; \
    curl -sSL -o protobuf-2.5.0.tar.gz https://github.com/protocolbuffers/protobuf/releases/download/v2.5.0/protobuf-2.5.0.tar.gz; \
    echo "c55aa3dc538e6fd5eaf732f4eb6b98bdcb7cedb5b91d3b5bdcf29c98c293f58e  protobuf-2.5.0.tar.gz" | sha256sum -c -; \
    tar xzf protobuf-2.5.0.tar.gz; \
    cd protobuf-2.5.0; \
    ./configure --prefix=/opt/protobuf-2.5.0 CXXFLAGS="-std=gnu++98 -fpermissive -w"; \
    make -j"$(nproc)"; \
    make install; \
    cd /tmp; rm -rf protobuf-2.5.0 protobuf-2.5.0.tar.gz; \
    /opt/protobuf-2.5.0/bin/protoc --version

ENV PATH=/opt/protobuf-2.5.0/bin:$PATH \
    LD_LIBRARY_PATH=/opt/protobuf-2.5.0/lib \
    HADOOP_PROTOC_PATH=/opt/protobuf-2.5.0/bin/protoc
