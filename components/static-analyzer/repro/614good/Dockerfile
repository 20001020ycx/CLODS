# syntax=docker/dockerfile:1
#
# Toolchain image for the CLODS static-analyzer reproduction. It builds only
# the analyzer's pinned dependencies (LLVM 14.0.0, Z3, gRPC + protoc +
# grpc_cpp_plugin); the analyzer source itself is exported from the component
# HEAD and compiled at run time by reproduce-614good.sh. The base image digest
# and all source revisions are pinned so reviewers can identify exactly what
# was used even if an upstream release tag later moves. gRPC's CMake install
# places protoc and grpc_cpp_plugin on /opt/grpc/bin (on PATH), which the
# analyzer's lib/ProtocBuf/CMakeLists.txt requires to generate the protobuf
# bindings from bm_protobuf/instrumentation.proto.
FROM ubuntu@sha256:21ae67bf44d1d0a53ecdce48742c766e44aea4d16e18a3b88a3888eddaf782b5

ARG DEBIAN_FRONTEND=noninteractive
ARG LLVM_ARCHIVE=clang+llvm-14.0.0-x86_64-linux-gnu-ubuntu-18.04.tar.xz
ARG LLVM_SHA256=61582215dafafb7b576ea30cc136be92c877ba1f1c31ddbbd372d6d65622fef5
ARG Z3_REV=e417f7d78509b2d0c9ebc911fee7632e6ef546b6
ARG GRPC_REV=6e85620c7e258df79666a4743f862f2f82701c2d

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        ninja-build \
        pkg-config \
        python3 \
        wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/src

RUN wget -q "https://github.com/llvm/llvm-project/releases/download/llvmorg-14.0.0/${LLVM_ARCHIVE}" \
    && printf '%s  %s\n' "${LLVM_SHA256}" "${LLVM_ARCHIVE}" | sha256sum --check - \
    && tar -xf "${LLVM_ARCHIVE}" -C /opt \
    && mv "/opt/${LLVM_ARCHIVE%.tar.xz}" /opt/llvm-14 \
    && rm "${LLVM_ARCHIVE}"

RUN git init z3 \
    && git -C z3 remote add origin https://github.com/Z3Prover/z3.git \
    && git -C z3 fetch --depth 1 origin "${Z3_REV}" \
    && git -C z3 checkout --detach FETCH_HEAD \
    && cmake -S z3 -B z3/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/z3 \
    && cmake --build z3/build --parallel \
    && cmake --install z3/build \
    && rm -rf z3

RUN git init grpc \
    && git -C grpc remote add origin https://github.com/grpc/grpc.git \
    && git -C grpc fetch --depth 1 origin "${GRPC_REV}" \
    && git -C grpc checkout --detach FETCH_HEAD \
    && git -C grpc submodule update --init --recursive --depth 1 \
    && cmake -S grpc -B grpc/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/grpc \
        -DgRPC_INSTALL=ON \
        -DgRPC_BUILD_TESTS=OFF \
        -DgRPC_BUILD_CSHARP_EXT=OFF \
        -DgRPC_BUILD_GRPC_CSHARP_PLUGIN=OFF \
        -DgRPC_BUILD_GRPC_NODE_PLUGIN=OFF \
        -DgRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN=OFF \
        -DgRPC_BUILD_GRPC_PHP_PLUGIN=OFF \
        -DgRPC_BUILD_GRPC_PYTHON_PLUGIN=OFF \
        -DgRPC_BUILD_GRPC_RUBY_PLUGIN=OFF \
        -DgRPC_ABSL_PROVIDER=module \
        -DgRPC_CARES_PROVIDER=module \
        -DgRPC_PROTOBUF_PROVIDER=module \
        -DgRPC_RE2_PROVIDER=module \
        -DgRPC_SSL_PROVIDER=module \
        -DgRPC_ZLIB_PROVIDER=module \
    && cmake --build grpc/build --parallel \
    && cmake --install grpc/build \
    && rm -rf grpc

ENV PATH=/opt/llvm-14/bin:/opt/grpc/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/llvm-14/lib:/opt/z3/lib:/opt/grpc/lib:${LD_LIBRARY_PATH}
ENV CMAKE_PREFIX_PATH=/opt/llvm-14/lib/cmake/llvm:/opt/z3/lib/cmake/z3:/opt/grpc

WORKDIR /work
CMD ["bash"]
