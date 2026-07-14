#!/usr/bin/env bash
set -euo pipefail

expected_commit="${HADOOP_COMMIT:-a4c88298d2439782b49b53e470c03a96e24773d6}"
expected_version="${HADOOP_VERSION:-2.7.1}"
output_name="hadoop-${expected_version}-${expected_commit:0:8}"
output_root="/artifact/output/${output_name}"
namenode_root="${output_root}/namenode"
llvm_nm="${GRAAL_LLVM:-/opt/graal/sdk/mxbuild/linux-amd64/LLVM_TOOLCHAIN/bin}/llvm-nm"
choose_symbol='BlockPlacementPolicyDefault_chooseRandom'

required_files=(
    "${output_root}/manifest.txt"
    "${output_root}/classpath.txt"
    "${output_root}/classpath.sha256"
    "${output_root}/verification/jvm-namenode-help.txt"
    "${output_root}/verification/native-namenode-help.txt"
    "${namenode_root}/namenode"
    "${namenode_root}/namenode.monolithic.bc"
    "${namenode_root}/function2IRmapping.txt"
    "${namenode_root}/target-functions.txt"
    "${namenode_root}/chooseRandom.bc"
    "${namenode_root}/chooseRandom.ll"
)
for required_file in "${required_files[@]}"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required artifact is missing or empty: ${required_file}" >&2
        exit 1
    fi
done

grep -q "${choose_symbol}" "${namenode_root}/function2IRmapping.txt"
grep -q "${choose_symbol}" "${namenode_root}/chooseRandom.ll"
gdis "${namenode_root}/namenode.monolithic.bc" -o /dev/null
gdis "${namenode_root}/chooseRandom.bc" -o /dev/null

# The JVM NameNode --help is the safe behavioural surface check. The native executable
# is produced for its LLVM bitcode/IR; under --allow-incomplete-classpath it may not run
# end to end, so its --help output is recorded but not required to match the JVM.
grep '^Usage:' "${output_root}/verification/jvm-namenode-help.txt" \
    > "${output_root}/verification/jvm-usage.txt"
if grep -q '^Usage:' "${output_root}/verification/native-namenode-help.txt"; then
    grep '^Usage:' "${output_root}/verification/native-namenode-help.txt" \
        > "${output_root}/verification/native-usage.txt"
    diff -u "${output_root}/verification/jvm-usage.txt" \
        "${output_root}/verification/native-usage.txt" \
        > "${output_root}/verification/usage-diff.txt" 2>&1 || true
else
    echo "native namenode --help did not reach Usage output; bitcode/IR remains the deliverable" \
        > "${output_root}/verification/native-usage.txt"
fi

# Symbol-count comparison against the historical reference bitcode, if it was
# mounted into the container. Both modules are measured with the same pinned
# Graal-managed llvm-nm, so the counts are directly comparable.
this_symbols="$("${llvm_nm}" --defined-only "${namenode_root}/namenode.monolithic.bc" 2>/dev/null | wc -l)"
this_choose="$("${llvm_nm}" --defined-only "${namenode_root}/namenode.monolithic.bc" 2>/dev/null | grep -c "${choose_symbol}")"
{
    echo "this_monolithic_defined_symbols=${this_symbols}"
    echo "this_choose_random_symbols=${this_choose}"
} >> "${output_root}/manifest.txt"

comparison_file="${output_root}/verification/comparison.txt"
{
    echo "metric reference(this_host_bc) this(namenode.monolithic.bc)"
    if [[ -f /input/reference.bc ]]; then
        ref_symbols="$("${llvm_nm}" --defined-only /input/reference.bc 2>/dev/null | wc -l)"
        ref_choose="$("${llvm_nm}" --defined-only /input/reference.bc 2>/dev/null | grep -c "${choose_symbol}")"
        ref_size="$(stat -c %s /input/reference.bc)"
        {
            echo "reference_artifact=${HADOOP_REFERENCE_BC:-/input/reference.bc}"
            echo "reference_size_bytes=${ref_size}"
            echo "reference_defined_symbols=${ref_symbols}"
            echo "reference_choose_random_symbols=${ref_choose}"
        } >> "${output_root}/manifest.txt"
        echo "type            LLVM-IR-bitcode          LLVM-IR-bitcode"
        echo "size_bytes      ${ref_size}              $(stat -c %s "${namenode_root}/namenode.monolithic.bc")"
        echo "defined_symbols ${ref_symbols}              ${this_symbols}"
        echo "chooseRandom_symbols ${ref_choose}               ${this_choose}"
    else
        echo "reference bitcode not mounted; comparison skipped"
        echo "this_defined_symbols ${this_symbols}"
        echo "this_chooseRandom_symbols ${this_choose}"
    fi
} > "${comparison_file}"

(
    cd "${output_root}"
    find . -type f \
        ! -path './namenode/native-image-tmp/*' \
        ! -name checksums.sha256 \
        -print0 \
        | sort -z \
        | xargs -0 sha256sum
) > "${output_root}/verification/checksums.sha256"

{
    stat -c 'native_executable=%s' "${namenode_root}/namenode"
    stat -c 'monolithic_bitcode=%s' "${namenode_root}/namenode.monolithic.bc"
    stat -c 'choose_random_bitcode=%s' "${namenode_root}/chooseRandom.bc"
    stat -c 'choose_random_llvm_ir=%s' "${namenode_root}/chooseRandom.ll"
    stat -c 'mapping=%s' "${namenode_root}/function2IRmapping.txt"
} > "${output_root}/verification/sizes.txt"

echo "Verified NameNode executable, mapping, monolithic bitcode, and chooseRandom IR."
echo "Comparison table: ${comparison_file}"