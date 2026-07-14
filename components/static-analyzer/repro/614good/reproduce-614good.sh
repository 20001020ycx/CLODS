#!/usr/bin/env bash
set -euo pipefail

# Reproduce the CLODS static-analyzer motivating example (HDFS-10453) on the
# monolithic LLVM module bytecode/614good.bc.
#
# This harness builds the ported config-driven StaticAnalysis source (from
# components/static-analyzer/StaticAnalysis, originally
# 06865b433bbb:/home/ridevsot/StaticAnalysis @ 222b486b) inside a pinned
# toolchain image, drives the five historically recorded manual-selection
# rounds with drive_rounds.py, and checks the captured plan against the
# reference manifest. The analyzer is config-driven: instead of patching a
# hard-coded bitcode path, the harness writes a CLODS.conf that points
# IRFilePath at the mounted 614good.bc.
#
# The recorded input ends after Round 5. The driver stops at the next prompt
# ("Was there a divergence point?") that the historical note never answers; it
# does not invent a Round 6.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_REPO=$(cd -- "$SCRIPT_DIR/../.." && pwd)
REFERENCE_MANIFEST=$SCRIPT_DIR/reference/manifest.json
REPRO_IMAGE=${REPRO_IMAGE:-clods-static-analyzer:local}
MAX_TRANSCRIPT_BYTES=67108864

read -r EXPECTED_BC_PATH EXPECTED_BC_BYTES EXPECTED_BC_SHA256 < <(
  python3 - "$REFERENCE_MANIFEST" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
bitcode = manifest["bitcode"]
print(bitcode["path"], bitcode["bytes"], bitcode["sha256"])
PY
)

repo=$DEFAULT_REPO
output=
build_image=0
overwrite=0
prompt_timeout=900
original_command=("$0" "$@")

usage() {
  cat <<'USAGE'
Usage: reproduce-614good.sh --output DIR [options]

Options:
  --repo DIR              Component root (default: detected from this script)
  --output DIR            New directory for captured evidence (required)
  --build-image           Build repro/614good/Dockerfile before running
  --image NAME            Reproduction image tag (default: clods-static-analyzer:local)
  --prompt-timeout SEC    Timeout for each analysis decision point (default: 900)
  --overwrite-output      Remove and recreate an existing output directory
  -h, --help              Show this help

The recorded input ends after Round 5. The driver stops before the first input
that is not present in the reference manifest (the undocumented divergence
prompt), so a successful bounded reproduction exits 0 with outcome
"incomplete-unrecorded-divergence-input".
USAGE
}

while (($#)); do
  case "$1" in
    --repo|--output|--image|--prompt-timeout)
      (($# >= 2)) || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
      option=$1
      value=$2
      case "$option" in
        --repo) repo=$value ;;
        --output) output=$value ;;
        --image) REPRO_IMAGE=$value ;;
        --prompt-timeout) prompt_timeout=$value ;;
      esac
      shift 2
      ;;
    --build-image) build_image=1; shift ;;
    --overwrite-output) overwrite=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$prompt_timeout" =~ ^[1-9][0-9]*$ ]] || {
  printf 'Invalid --prompt-timeout: %s (expected a positive integer)\n' "$prompt_timeout" >&2
  exit 2
}
[[ -n "$output" ]] || { printf '%s\n' '--output is required' >&2; exit 2; }
repo=$(realpath "$repo")
output=$(realpath -m "$output")

case "$output/" in
  "$repo/"|"$repo/"*)
    printf 'Output must be outside the repository checkout: %s\n' "$output" >&2
    exit 2
    ;;
esac
case "$repo/" in
  "$output/"*)
    printf 'Output must not contain the repository checkout: %s\n' "$output" >&2
    exit 2
    ;;
esac

[[ -e "$repo/.git" ]] || { printf 'Not a Git checkout: %s\n' "$repo" >&2; exit 2; }
[[ -f "$repo/$EXPECTED_BC_PATH" ]] || { printf 'Missing %s\n' "$repo/$EXPECTED_BC_PATH" >&2; exit 2; }
[[ -f "$repo/StaticAnalysis/lib/ProtocBuf/bm_protobuf/instrumentation.proto" ]] || {
  printf '%s\n' 'Missing vendored protobuf: StaticAnalysis/lib/ProtocBuf/bm_protobuf/instrumentation.proto' >&2
  exit 2
}

actual_sha=$(sha256sum "$repo/$EXPECTED_BC_PATH" | cut -d' ' -f1)
actual_bytes=$(stat -c '%s' "$repo/$EXPECTED_BC_PATH")
[[ "$actual_sha" == "$EXPECTED_BC_SHA256" ]] || {
  printf 'Unexpected 614good.bc SHA-256: %s\n' "$actual_sha" >&2
  exit 2
}
[[ "$actual_bytes" == "$EXPECTED_BC_BYTES" ]] || {
  printf 'Unexpected 614good.bc size: %s\n' "$actual_bytes" >&2
  exit 2
}

if [[ -e "$output" ]]; then
  if ((overwrite)); then
    rm -rf -- "$output"
  else
    printf 'Output already exists: %s (use --overwrite-output)\n' "$output" >&2
    exit 2
  fi
fi
mkdir -p "$output"

{
  printf 'repository=%s\n' "$repo"
  printf 'head=%s\n' "$(git -C "$repo" rev-parse HEAD)"
  printf 'bitcode_sha256=%s\n' "$actual_sha"
  printf 'bitcode_bytes=%s\n' "$actual_bytes"
  printf 'reproduction_image=%s\n' "$REPRO_IMAGE"
  printf 'command='; printf '%q ' "${original_command[@]}"; printf '\n'
} > "$output/run-metadata.txt"
git -C "$repo" status --short > "$output/git-status.txt"
file "$repo/$EXPECTED_BC_PATH" > "$output/bitcode-file.txt"
cp "$SCRIPT_DIR/reference/manifest.json" "$output/reference-manifest.json"

if ((build_image)); then
  docker build --file "$SCRIPT_DIR/Dockerfile" --tag "$REPRO_IMAGE" "$SCRIPT_DIR" \
    > "$output/docker-build.log" 2>&1
fi

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }
if ! image_exists "$REPRO_IMAGE"; then
  printf 'Reproduction image %s does not exist. Build it first with --build-image.\n' \
    "$REPRO_IMAGE" >&2
  exit 2
fi

prepare_source() {
  local result_dir=$1
  local source_dir=$result_dir/source
  mkdir -p "$source_dir/bytecode"

  # Export the tracked StaticAnalysis source tree (the ported config-driven
  # analyzer) from the component HEAD. git archive includes the vendored
  # bm_protobuf/instrumentation.proto as plain files (no submodule gitlink).
  git -C "$repo" archive HEAD StaticAnalysis | tar -x -C "$source_dir"

  # The analyzer is config-driven: write CLODS.conf at the source root (it
  # reads ../CLODS.conf from build/) pointing IRFilePath at the mounted
  # bitcode. jumpTable.conf is already in the archive; rewrite it explicitly
  # so the run does not depend on the archive's default.
  cat > "$source_dir/StaticAnalysis/CLODS.conf" <<EOF
enableNetwork: 0
debugLevel: 3
manualOverride: 1
debug: DataDependencyPass, ProtocBuf
IRFilePath: /results/source/bytecode/614good.bc
FileName: BlockPlacementPolicyDefault.java
LineNumber: 551
EOF
  printf 'DataNode.registerDatanode:NameNode.registerDatanode\n' \
    > "$source_dir/StaticAnalysis/jumpTable.conf"

  ln "$repo/$EXPECTED_BC_PATH" "$source_dir/bytecode/614good.bc" 2>/dev/null \
    || cp "$repo/$EXPECTED_BC_PATH" "$source_dir/bytecode/614good.bc"
}

result_dir="$output/current"
prepare_source "$result_dir"
docker image inspect "$REPRO_IMAGE" > "$result_dir/image-inspect.json"
set +e
docker run --rm --network none \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$result_dir:/results" \
  -v "$SCRIPT_DIR/drive_rounds.py:/harness/drive_rounds.py:ro" \
  -v "$REFERENCE_MANIFEST:/harness/manifest.json:ro" \
  "$REPRO_IMAGE" bash -lc '
    set -euo pipefail
    trap '\''chown -R "$HOST_UID:$HOST_GID" /results'\'' EXIT
    source_dir=/results/source
    export PATH=/opt/llvm-14/bin:/opt/grpc/bin:$PATH
    llvm_dir=/opt/llvm-14/lib/cmake/llvm
    z3_dir=/opt/z3/lib/cmake/z3
    protobuf_dir=/opt/grpc/lib/cmake/protobuf
    grpc_dir=/opt/grpc/lib/cmake/grpc
    include_path=/opt/grpc/include
    cmake -S "$source_dir/StaticAnalysis" -B "$source_dir/StaticAnalysis/build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Debug \
      -DLLVM_DIR="$llvm_dir" \
      -DZ3_DIR="$z3_dir" \
      -Dprotobuf_DIR="$protobuf_dir" \
      -DgRPC_DIR="$grpc_dir" \
      -DCMAKE_INCLUDE_PATH="$include_path" \
      > /results/configure.log 2>&1
    cmake --build "$source_dir/StaticAnalysis/build" --parallel > /results/build.log 2>&1
    status=0
    python3 /harness/drive_rounds.py \
      --binary "$source_dir/StaticAnalysis/build/static-analysis" \
      --cwd "$source_dir/StaticAnalysis/build" \
      --transcript /results/session.log \
      --result /results/driver-result.json \
      --manifest /harness/manifest.json \
      --prompt-timeout '"$prompt_timeout"' \
      --max-transcript-bytes '"$MAX_TRANSCRIPT_BYTES"' || status=$?
    exit "$status"
  '
driver_status=$?
set -e

validation_status=0

if ((driver_status == 0)) && [[ -s "$result_dir/session.log" ]]; then
  session_bytes=$(stat -c '%s' "$result_dir/session.log")
  if ((session_bytes > MAX_TRANSCRIPT_BYTES)); then
    printf 'Transcript is too large to normalize safely: %s bytes (limit %s)\n' \
      "$session_bytes" "$MAX_TRANSCRIPT_BYTES" > "$result_dir/reference-comparison.txt"
    validation_status=2
  elif ! python3 "$SCRIPT_DIR/normalize_rules.py" "$result_dir/session.log" \
    --output "$result_dir/normalized-rules.json"; then
    printf '%s\n' 'Rule normalization failed.' > "$result_dir/reference-comparison.txt"
    validation_status=2
  fi
elif ((driver_status == 0)); then
  printf '%s\n' 'Analyzer transcript was not produced.' > "$result_dir/reference-comparison.txt"
  validation_status=2
fi

if ((driver_status == 0 && validation_status == 0)); then
  if ! python3 "$SCRIPT_DIR/compare_reference.py" "$result_dir/normalized-rules.json" \
    --manifest "$REFERENCE_MANIFEST" \
    --output "$result_dir/reference-comparison.json" \
    > "$result_dir/reference-comparison.txt" 2>&1; then
    validation_status=2
  fi
fi

find "$result_dir" -type f ! -path "$result_dir/artifact-inventory.tsv" \
  ! -path "$result_dir/source/StaticAnalysis/build/*" \
  ! -wholename "$result_dir/source/bytecode/*" \
  -printf '%P\t%s\t' -exec sha256sum {} \; \
  | sort > "$result_dir/artifact-inventory.tsv"

printf 'Reproduction evidence: %s\n' "$result_dir"
if [[ -s "$result_dir/driver-result.json" ]]; then
  python3 - "$result_dir/driver-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(f"Outcome: {result['outcome']}")
print(f"Detail: {result['detail']}")
PY
else
  printf 'Outcome: build-or-driver-failure (exit %s)\n' "$driver_status"
fi
if ((driver_status != 0)); then
  exit "$driver_status"
fi
exit "$validation_status"