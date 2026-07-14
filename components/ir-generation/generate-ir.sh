#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_vars.sh
source "${script_dir}/shared_vars.sh"

if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container '${CONTAINER_NAME}' is not running. Run ./run.sh first." >&2
    exit 1
fi

if [[ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")" != "true" ]]; then
    docker start "${CONTAINER_NAME}" >/dev/null
fi

docker exec --interactive --user "${DOCKER_USER}" "${CONTAINER_NAME}" bash -lc '
    set -euo pipefail

    cd /workspace
    rm -rf output
    mkdir -p output/classes output/native-image-tmp

    echo "[1/5] Compiling Java source to bytecode"
    javac -g -d output/classes SimpleMath.java

    echo "[2/5] Running the Java bytecode"
    java -cp output/classes SimpleMath 10 | tee output/java-output.txt

    echo "[3/5] Building a native executable through the LLVM backend"
    cd /opt/graal/substratevm
    mx native-image \
        -cp /workspace/output/classes \
        -H:Class=SimpleMath \
        -H:Name=/workspace/output/simple-math \
        -H:CompilerBackend=llvm \
        -H:LLVMMaxFunctionsPerBatch=1 \
        -H:DumpLLVMStackMap=/workspace/output/function2IRmapping.txt \
        -H:TempDirectory=/workspace/output/native-image-tmp \
        -H:DeadlockWatchdogInterval=0 \
        -H:-InlineDuringParsing \
        -H:-InlineIntrinsicsDuringParsing \
        -H:-Inline \
        -H:-AOTInline \
        -H:-AOTTrivialInline \
        -H:-OmitInlinedMethodDebugLineInfo \
        --no-fallback \
        --install-exit-handlers \
        -O0 \
        -g

    echo "[4/5] Running the native executable"
    /workspace/output/simple-math 10 | tee /workspace/output/native-output.txt
    diff -u /workspace/output/java-output.txt /workspace/output/native-output.txt

    echo "[5/5] Finding SimpleMath methods and disassembling their LLVM bitcode"
    map_file=/workspace/output/function2IRmapping.txt
    llvm_dir="$(find /workspace/output/native-image-tmp -type d -name llvm -print -quit)"
    if [[ -z "${llvm_dir}" ]]; then
        echo "Native Image did not create an LLVM intermediate directory." >&2
        exit 1
    fi
    grep "SimpleMath" "${map_file}" | tee /workspace/output/simple-math-functions.txt

    found=0
    while read -r method_name arrow function_id remainder; do
        if [[ "${arrow}" != "->" || ! "${function_id}" =~ ^f[0-9]+$ ]]; then
            continue
        fi

        bc_file="${llvm_dir}/${function_id}.bc"
        if [[ -f "${bc_file}" ]]; then
            gdis "${bc_file}" -o "/workspace/output/${function_id}.ll"
            echo "Created output/${function_id}.ll from ${bc_file}"
            found=1
        fi
    done < <(grep -E "^SimpleMath[^ ]* -> f[0-9]+ " "${map_file}")

    if [[ "${found}" -ne 1 ]]; then
        echo "No SimpleMath bitcode files were found from the mapping." >&2
        exit 1
    fi

    llvm_host_path="${llvm_dir#/workspace/}"

    echo
    echo "Success. Host-visible artifacts:"
    echo "  output/simple-math                  native executable"
    echo "  output/function2IRmapping.txt       Java method -> fNNN mapping"
    echo "  ${llvm_host_path}/*.bc   LLVM bitcode"
    echo "  output/fNNN.ll                      readable LLVM IR for SimpleMath"
'
