#!/usr/bin/env bash
set -euo pipefail

expected_commit="${HADOOP_COMMIT:-a4c88298d2439782b49b53e470c03a96e24773d6}"
expected_version="${HADOOP_VERSION:-2.7.1}"
hadoop_source_host="${HADOOP_SOURCE:-/home/ycx/research/bug/MotivatingExample}"
output_name="hadoop-${expected_version}-${expected_commit:0:8}"
output_root="/artifact/output/${output_name}"
work_root="/work/${output_name}"
source_root="${work_root}/source"
classpath_dir="${output_root}/classpath"

input_commit="$(git -C /input/hadoop rev-parse HEAD)"
if [[ "${input_commit}" != "${expected_commit}" ]]; then
    echo "Unexpected Hadoop commit: ${input_commit}; expected ${expected_commit}." >&2
    exit 1
fi
if [[ -n "$(git -C /input/hadoop status --porcelain --untracked-files=no)" ]]; then
    echo "The authoritative Hadoop checkout has tracked changes; refusing to build it." >&2
    git -C /input/hadoop status --short >&2
    exit 1
fi
if ! grep -q "<version>${expected_version}</version>" /input/hadoop/pom.xml; then
    echo "The root POM does not declare Hadoop ${expected_version}." >&2
    exit 1
fi

for source_file in \
    hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/NameNode.java \
    hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/BlockPlacementPolicyDefault.java; do
    if [[ ! -f "/input/hadoop/${source_file}" ]]; then
        echo "Missing required source: ${source_file}" >&2
        exit 1
    fi
done

rm -rf "${source_root}" "${output_root}"
mkdir -p "${source_root}" "${classpath_dir}" "${output_root}/verification"
rsync -a --delete --exclude target/ /input/hadoop/ "${source_root}/"

{
    echo "source_path=${hadoop_source_host}"
    echo "source_commit=${input_commit}"
    echo "source_version=${expected_version}"
    printf 'source_ref='; git -C /input/hadoop symbolic-ref --short -q HEAD || echo detached
    printf 'source_status='; if [[ -z "$(git -C /input/hadoop status --porcelain --untracked-files=no)" ]]; then echo clean; else echo modified; fi
    printf 'java_version='; java -version 2>&1 | head -n 1
    printf 'maven_version='; mvn --version | head -n 1
    printf 'protoc_version='; protoc --version
    printf 'graal_commit='; git -C /opt/graal rev-parse HEAD
    printf 'mx_commit='; git -C /opt/mx rev-parse HEAD
    printf 'llvm_version='; "${GRAAL_LLVM}/llvm-dis" --version | head -n 1
} > "${output_root}/manifest.txt"

cd "${source_root}"

mvn -B -ntp \
    -pl hadoop-hdfs-project/hadoop-hdfs \
    -am \
    -DskipTests \
    -Dmaven.test.skip=true \
    -DskipITs \
    install \
    2>&1 | tee "${output_root}/maven-build.log"

hdfs_module="${source_root}/hadoop-hdfs-project/hadoop-hdfs"
mvn -B -ntp \
    -f "${hdfs_module}/pom.xml" \
    -DincludeScope=compile \
    -DexcludeTransitive=false \
    -DoutputDirectory="${classpath_dir}" \
    dependency:copy-dependencies \
    2>&1 | tee "${output_root}/maven-classpath.log"

cp "${hdfs_module}/target/hadoop-hdfs-${expected_version}.jar" "${classpath_dir}/"
mvn -B -ntp -f "${hdfs_module}/pom.xml" help:effective-pom \
    -Doutput="${output_root}/effective-hdfs-pom.xml"

find "${classpath_dir}" -maxdepth 1 -type f -name '*.jar' -printf '%p\n' | sort \
    | paste -sd: - > "${output_root}/classpath.txt"
find "${classpath_dir}" -maxdepth 1 -type f -name '*.jar' -printf '%f\n' | sort \
    > "${output_root}/resolved-dependencies.txt"
(
    cd "${classpath_dir}"
    sha256sum ./*.jar | sort -k2
) > "${output_root}/classpath.sha256"

classpath="$(<"${output_root}/classpath.txt")"
javap -classpath "${classpath}" org.apache.hadoop.hdfs.server.namenode.NameNode \
    > "${output_root}/verification/javap-namenode.txt"
javap -classpath "${classpath}" org.apache.hadoop.hdfs.server.blockmanagement.BlockPlacementPolicyDefault \
    > "${output_root}/verification/javap-block-placement-policy.txt"

set +e
timeout 30 java -cp "${classpath}" org.apache.hadoop.hdfs.server.namenode.NameNode --help \
    > "${output_root}/verification/jvm-namenode-help.txt" 2>&1
help_status=$?
set -e
if [[ "${help_status}" -ne 0 ]]; then
    echo "JVM NameNode --help failed with status ${help_status}." >&2
    cat "${output_root}/verification/jvm-namenode-help.txt" >&2
    exit "${help_status}"
fi
if ! grep -q "Usage:" "${output_root}/verification/jvm-namenode-help.txt"; then
    echo "JVM NameNode --help did not print usage." >&2
    exit 1
fi

printf 'classpath_entries=%s\n' "$(find "${classpath_dir}" -maxdepth 1 -type f -name '*.jar' | wc -l)" \
    >> "${output_root}/manifest.txt"
echo "Built Hadoop ${expected_version} and staged the NameNode classpath at ${output_root}."