#!/usr/bin/env bash
set -euo pipefail

expected_commit="${HADOOP_COMMIT:-a4c88298d2439782b49b53e470c03a96e24773d6}"
expected_version="${HADOOP_VERSION:-2.7.1}"
build_mode="${HDFS_NATIVE_IMAGE_MODE:-compat}"
output_name="hadoop-${expected_version}-${expected_commit:0:8}"
output_root="/artifact/output/${output_name}"
namenode_root="${output_root}/namenode"
classpath_file="${output_root}/classpath.txt"
log_file="${namenode_root}/native-image.log"

if [[ ! -s "${classpath_file}" ]]; then
    echo "Missing staged classpath. Run container/build-hadoop.sh first." >&2
    exit 1
fi

rm -rf "${namenode_root}"
mkdir -p "${namenode_root}/native-image-tmp"
cp -r /artifact/metadata "${output_root}/metadata"

classpath="$(<"${classpath_file}")"
compatibility_options=()
case "${build_mode}" in
    strict)
        ;;
    compat)
        compatibility_options+=(--allow-incomplete-classpath --report-unsupported-elements-at-runtime)
        ;;
    *)
        echo "Unknown HDFS_NATIVE_IMAGE_MODE '${build_mode}'; use strict or compat." >&2
        exit 1
        ;;
esac

echo "native_image_mode=${build_mode}" >> "${output_root}/manifest.txt"

cd /opt/graal/substratevm
set +e
mx native-image \
    -cp "${classpath}" \
    -H:Class=org.apache.hadoop.hdfs.server.namenode.NameNode \
    -H:Name="${namenode_root}/namenode" \
    -H:CompilerBackend=llvm \
    -H:LLVMMaxFunctionsPerBatch=0 \
    -H:DumpLLVMStackMap="${namenode_root}/function2IRmapping.txt" \
    -H:TempDirectory="${namenode_root}/native-image-tmp" \
    -H:ReflectionConfigurationFiles=/artifact/metadata/reflect-config.json \
    -H:ResourceConfigurationFiles=/artifact/metadata/resource-config.json \
    -H:DynamicProxyConfigurationFiles=/artifact/metadata/proxy-config.json \
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
    -g \
    "${compatibility_options[@]}" \
    2>&1 | tee "${log_file}"
native_status=${PIPESTATUS[0]}
set -e
if [[ "${native_status}" -ne 0 ]]; then
    echo "Native Image failed in ${build_mode} mode; see ${log_file}." >&2
    exit "${native_status}"
fi

llvm_dir="$(find "${namenode_root}/native-image-tmp" -type d -name llvm -print -quit)"
if [[ -z "${llvm_dir}" ]]; then
    echo "Native Image did not preserve an LLVM intermediate directory." >&2
    exit 1
fi

batch_bc="$(find "${llvm_dir}" -maxdepth 1 -type f \( -name 'b0.bc' -o -name 'b0o.bc' \) -print | sort | tail -n 1)"
if [[ -z "${batch_bc}" ]]; then
    echo "Native Image did not emit a batch bitcode module." >&2
    exit 1
fi
cp "${batch_bc}" "${namenode_root}/namenode.monolithic.bc"
gdis "${namenode_root}/namenode.monolithic.bc" -o /dev/null

grep "BlockPlacementPolicyDefault" "${namenode_root}/function2IRmapping.txt" \
    > "${namenode_root}/target-functions.txt"

# Match the real chooseRandom method symbols exactly: ClassName_method_<40-char hash>.
# Avoid nested methods whose symbol also begins with chooseRandom_ (e.g. an inner equals).
# Among the chooseRandom overloads, prefer the largest compiled function: it is the
# int-numOfReplicas overload at BlockPlacementPolicyDefault.java:613 that contains the
# replica-selection loop and NotEnoughReplicasException analysed in the paper.
choose_line="$(grep -E '^BlockPlacementPolicyDefault_chooseRandom_[0-9a-f]{40} -> f[0-9]+ ' \
    "${namenode_root}/function2IRmapping.txt" \
    | sort -t'(' -k2 -n | tail -n 1)"
if [[ -z "${choose_line}" ]]; then
    echo "No top-level BlockPlacementPolicyDefault.chooseRandom mapping was found." >&2
    exit 1
fi
read -r _ _ function_id _ <<< "${choose_line}"
choose_bc="${llvm_dir}/${function_id}.bc"
if [[ ! -s "${choose_bc}" ]]; then
    echo "Mapped chooseRandom bitcode '${choose_bc}' is missing or empty." >&2
    exit 1
fi
cp "${choose_bc}" "${namenode_root}/chooseRandom.bc"
gdis "${namenode_root}/chooseRandom.bc" -o "${namenode_root}/chooseRandom.ll"

# Parse Native Image's own phase summary from the log so timing provenance is
# reproducible without a manual post-processing step. The log prints lines of the
# form  [image:pid] <label>: N,NNN.NN ms, N.NN GB  ending with a [total] line.
parse_log() {
    awk '
    function record(label, msnum, gbnum) {
        if (label == "analysis")        analysis = msnum
        else if (label == "(compile)")  compile = msnum
        else if (label == "(bitcode)")  bitcode = msnum
        else if (label == "(llvm)")      llvm = msnum
        else if (label == "(postlink)") postlink = msnum
        else if (label == "image")       image = msnum
        else if (label == "write")       write = msnum
        else if (label == "[total]")     { total = msnum; if (gbnum != "") peak = gbnum }
    }
    {
        if (index($0, " ms,") == 0) next
        b = index($0, "] "); if (b == 0) next
        after = substr($0, b + 2)
        c = index(after, ":"); if (c == 0) next
        label = substr(after, 1, c - 1); gsub(/^ +| +$/, "", label)
        rest = substr(after, c + 1); gsub(/^[ ]+/, "", rest)
        n = split(rest, parts, " ms,")
        if (n < 1) next
        gsub(/,/, "", parts[1]); msnum = parts[1] + 0
        gbnum = ""
        if (n >= 2) { gsub(/[^0-9.]/, "", parts[2]); if (parts[2] != "") gbnum = parts[2] }
        record(label, msnum, gbnum)
    }
    END {
        if (total != "")  printf "native_image_total_ms=%.0f\n", total
        if (peak != "")   printf "native_image_peak_gb=%s\n", peak
        line = ""
        if (analysis != "")  line = line "analysis:" sprintf("%.0f", analysis) "ms "
        if (compile != "")  line = line "compile:" sprintf("%.0f", compile) "ms "
        if (bitcode != "")   line = line "bitcode:" sprintf("%.0f", bitcode) "ms "
        if (llvm != "")      line = line "llvm:" sprintf("%.0f", llvm) "ms "
        if (postlink != "")  line = line "postlink:" sprintf("%.0f", postlink) "ms "
        if (image != "")     line = line "image:" sprintf("%.0f", image) "ms "
        if (write != "")     line = line "write:" sprintf("%.0f", write) "ms "
        sub(/ $/, "", line)
        if (line != "") printf "native_image_phases=%s\n", line
    }
    ' "$1"
}
# Also keep the full native-image phase block for full-fidelity inspection.
grep -E '\] +[^ ]+:.* ms,.* GB' "${log_file}" > "${namenode_root}/native-image-summary.txt" || true
parse_log "${log_file}" >> "${output_root}/manifest.txt"

# The deliverable is the LLVM bitcode/IR, not a fully runnable native daemon. With
# --allow-incomplete-classpath the executable may still throw at runtime for classes
# omitted from the image. Record the native --help behaviour without failing the build.
set +e
timeout 30 "${namenode_root}/namenode" --help \
    > "${output_root}/verification/native-namenode-help.txt" 2>&1
help_status=$?
set -e
{
    echo "native_namenode_help_status=${help_status}"
    if [[ "${help_status}" -ne 0 ]]; then
        echo "native_namenode_help_note=executable produced but --help did not complete (expected under incomplete-classpath); bitcode/IR is the deliverable"
    fi
} >> "${output_root}/manifest.txt"

{
    echo "llvm_directory=${llvm_dir}"
    echo "monolithic_source=${batch_bc}"
    echo "choose_random_mapping=${choose_line}"
    echo "choose_random_function_id=${function_id}"
    echo "raw_function_bitcode_count=$(find "${llvm_dir}" -maxdepth 1 -regextype posix-extended -type f -regex '.*/f[0-9]+\.bc' | wc -l)"
    echo "zero_length_raw_bitcode_count=$(find "${llvm_dir}" -maxdepth 1 -regextype posix-extended -type f -regex '.*/f[0-9]+\.bc' -size 0 | wc -l)"
} >> "${output_root}/manifest.txt"

echo "Generated NameNode LLVM artifacts under ${namenode_root}."