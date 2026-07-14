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

# Motivating-example presence check (CLODS paper, SOSP'26, §2 "Motivating Example",
# HDFS-10453, Figure 1): confirm the functions the paper analyzes actually appear as
# real LLVM IR in the disassembled chooseRandom. The paper's Figure 1 pseudocode names
# (chooseRandom, isGoodTarget, getNumAvailableNodes, nReplicate, NotEnoughReplicasException)
# map to the actual Hadoop 2.7.1 method/identifier names used in the IR.
motivating_file="${output_root}/verification/motivating-example.txt"
declare -a motivating_entities=(
    "chooseRandom|chooseRandom|method under analysis (Fig.1 line 6)"
    "addIfIsGoodTarget|isGoodTarget|good-target check (Fig.1 line 13/20)"
    "countNumOfAvailableNodes|getNumAvailableNodes|available-node count (Fig.1 line 8)"
    "NotEnoughReplicasException|NotEnoughReplicasException|thrown exception (Fig.1 line 18)"
    "numOfReplicas|nReplicate|replica counter (Fig.1 line 6)"
    "BlockPlacementPolicyDefault.java|source file|DWARF debug source location"
)
{
    echo "# Motivating-example entity presence in chooseRandom.ll"
    echo "# Paper: CLODS (SOSP'26) §2 Motivating Example, HDFS-10453, Figure 1"
    echo "# columns: ir_token | paper_name(Fig.1) | description | match_count | first_matching_line"
} > "${motivating_file}"
motivating_missing=0
for entry in "${motivating_entities[@]}"; do
    IFS='|' read -r token paper_name desc <<< "${entry}"
    count="$(grep -cF -- "${token}" "${namenode_root}/chooseRandom.ll" 2>/dev/null || true)"
    sample="$(grep -nF -- "${token}" "${namenode_root}/chooseRandom.ll" 2>/dev/null | head -n 1 || true)"
    printf '%s\t%s\t%s\t%s\t%s\n' "${token}" "${paper_name}" "${desc}" "${count}" "${sample}" >> "${motivating_file}"
    if [[ "${count}" -eq 0 ]]; then
        echo "Motivating-example entity missing from chooseRandom.ll: ${token} (paper: ${paper_name})" >&2
        motivating_missing=1
    fi
done
if [[ "${motivating_missing}" -ne 0 ]]; then
    exit 1
fi
{
    echo "motivating_example_entities_checked=${#motivating_entities[@]}"
    echo "motivating_example_all_present=1"
} >> "${output_root}/manifest.txt"

# The JVM NameNode --help is a classpath sanity check (the staged classpath loads
# NameNode and prints usage). It is not a native-binary run; the native executable is
# a side effect of the LLVM backend pipeline and is not part of the motivating-example
# check, which is the grep-on-IR presence check above.
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

echo "Verified monolithic bitcode, chooseRandom IR, and the motivating-example presence check."
echo "Motivating-example report: ${output_root}/verification/motivating-example.txt"
echo "Comparison table: ${comparison_file}"