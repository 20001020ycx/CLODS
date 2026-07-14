# CLODS - Static Analyzer

Backward control/data-flow + call-site analysis over a monolithic LLVM IR module: given the IR and a failure-relevant Java source location, emit an instrumentation plan that localizes the root cause. Reproduces the paper's motivating example, HDFS-10453 (CLODS, SOSP'26, §2 "Motivating Example").

Everything runs in Docker. No host LLVM, Z3, or protobuf is required. Requirements: Linux x86-64, Docker Engine, Git LFS, internet during image build, ~2 GB disk for the bitcode.

> **Determinism note.** LLVM IR generation (the `ir-generation` component) may reorder functions across runs/versions, which would change the analyzer's plan numbering. The static analyzer therefore consumes a **pinned pre-compiled module**, `bytecode/motivating_example_full.bc` (316 MB, Git LFS), so the plan is reproducible. Hydrate it with `git lfs pull --include='components/static-analyzer/bytecode/motivating_example_full.bc'`. To inspect the IR, disassemble on demand (do not commit the ~1.6 GB output):
>
> ```bash
> llvm-dis bytecode/motivating_example_full.bc -o motivating_example_full.ll   # ~1 min, ~1.6 GB
> ```

## 1) Reproduce the motivating example (HDFS-10453)

The analyzer is config-driven: `CLODS.conf` selects the IR module and the seed location (`BlockPlacementPolicyDefault.java:551`). The harness exports the tracked `StaticAnalysis/` source from `HEAD`, compiles it in a pinned toolchain image, drives the historically recorded manual-selection rounds, and checks the plan against the reference. Steps (run from this directory):

```bash
out="$HOME/clods-static-analyzer-$(date +%Y%m%d-%H%M%S)"
bash repro/motivating_example/reproduce.sh --build-image --output "$out"
```

`--build-image` builds the pinned toolchain image (`repro/motivating_example/Dockerfile`: LLVM 14.0.0, Z3, gRPC + `protoc` + `grpc_cpp_plugin`) once; omit it on later runs. Runtime networking is disabled. ~3–4 min after the image is built (the 316 MB IR is parsed once).

### What to check

Expected outcome (exit `0`):

```text
Outcome: incomplete-unrecorded-divergence-input
Detail: The next required input was an undocumented divergence answer.
```

`incomplete-unrecorded-divergence-input` is the *intended* success: all six recorded decisions were driven and all five plans matched, then the driver stopped at the `Was there a divergence point?` prompt the historical note never answers — it does **not** invent a Round 6.

```bash
d="$out/current"
cat "$d/driver-result.json"        # completedSelectionCount == expectedSelectionCount == 6
cat "$d/reference-comparison.json" # {"match": true, "matchedRounds": [1,2,3,4,5], "mismatches": []}
diff "$d/session.log" repro/motivating_example/reference/transcript-motivating-example-ref.log  # byte-identical
```

The wrapper exits non-zero on any build failure, timeout, normalization failure, or semantic mismatch; exit `0` plus `match: true` is the reproduction criterion.

## 2) The five rounds, mapped to the paper

The tool emits five concrete rounds on the real 316 MB IR (real source lines + bytecode indexes, captured in `reference/manifest.json`); the paper presents the same example on abridged pseudocode. Building blocks (paper §5): **CDA** (control dependency → CBIs), **DDA** (data dependency → definitions), **CSA** (call sites → callers); deviation types: **location** vs **branch**.

| Round | Tool selection | Paper step | Building block |
|---|---|---|---|
| 1 | `chooseRandom` ID 1 (line 528) | symptom (line 18) is a location deviation → CDA returns `if nReplicate>0` (line 17) | Location + CDA |
| 2 | `addIfIsGoodTarget` ID 0 (line 571) | branch deviation at line 17 → DDA on `nReplicate` → def line 14 + CBIs 13/11/9; logs pin line 13 | Branch + DDA |
| 3 | `isGoodTarget` ID 3 (line 642) | branch deviation at line 13 → DDA into `isGoodTarget` predicates (lines 22/23) | Branch + DDA |
| 4 | branch 0, ID 3 (`chooseTarget`, line 305) | line-23 predicate forks: `blockSize` (arg) → CSA → callers (branch 0); `node.getRemaining()` (shared) → field writers (branches 1/2) | Branch + DDA + CSA |
| 5 | `BlockManager.chooseTargets` ID 0 (line 3518) | CSA up the caller chain toward `chooseRandom(b.numReplicas, b.size)` (line 4) → `b.size` | CSA → termination |

After Round 5 the analyzer asks `Was there a divergence point?`. The historical note records Rounds 1–5 only, so the driver stops here. The destination it traces toward is the root cause: a **data race on `b.size`** — the deletion thread's `b.setBlockSize(Long.MAX_VALUE)` vs the block constructor's `INIT_SIZE` — which makes `isGoodTarget` always return false at line 23, so replication never succeeds (HDFS-10453).

## 3) Fast unit test (same example, 33 MB IR)

For a quicker smoke-test of the same pipeline, run the abridged module:

```bash
bash repro/motivating_example/reproduce.sh --fast --build-image --output "$out-fast"
```

`--fast` swaps in `bytecode/motivating_example_fast.bc` (33 MB) and `reference/manifest-fast.json`. Expected outcome (exit `0`):

```text
Outcome: stopped-before-unspecified-round-6-selection
Detail: Captured the next plan and stopped at its id prompt.
```

Why it serves the same purpose as the full module: same analyzer, same seed (`BlockPlacementPolicyDefault.java:551`), same target method (`chooseRandom`), same CDA/DDA/CSA building blocks. The two references are **byte-identical through Round 3** (`chooseRandom` → `addIfIsGoodTarget` → `isGoodTarget`) and present the **same Round-4 fork** (the 3-branch `blockSize` / `node.getRemaining()` split that is the crux of the motivating example). They diverge only at the Round-4 id pick: the full module picks ID 3 → `chooseTarget` → Round 5 `chooseTargets` (then stops at the divergence prompt); the fast module picks ID 0 → `chooseLocalRack` → Round 6 `chooseLocalStorage` (then stops at the Round-6 id prompt). So the fast path is a faithful, ~10×-faster-parse exercise of the same analysis on the same bug, not a byte-copy of the full 5-round reference.

```bash
d="$out-fast/current"
cat "$d/reference-comparison.json" # {"match": true, "matchedRounds": [1,2,3,4,5,6], "mismatches": []}
diff "$d/session.log" repro/motivating_example/reference/transcript-fast-ref.log  # byte-identical
```

## Inputs & provenance

- **Bitcode** — `bytecode/motivating_example_full.bc` (316,482,648 bytes; sha-256 `a0ca09ca4d4919ceffa29567ff723d2f941210d9de39503b9ac2741da5c1c2b6`) and `bytecode/motivating_example_fast.bc` (33,773,756 bytes; sha-256 `82fc7bb695fef9654cab68a12d521875963e37a154c1609c6f679afc309576a4`), both Git LFS (`.gitattributes`).
- **Analyzer source** — `StaticAnalysis/`, ported from container `06865b433bbb:/home/ridevsot/StaticAnalysis` @ `222b486b`; protobuf schema vendored at `lib/ProtocBuf/bm_protobuf/instrumentation.proto` (no submodule).
- **Reference** — `repro/motivating_example/reference/manifest.json` + `transcript-motivating-example-ref.log` (full); `manifest-fast.json` + `transcript-fast-ref.log` (fast). A clean from-source build was verified to reproduce the full reference byte-identically (see `manifest.json` → `analyzerProvenance.fromSourceBuildVerified`); the fast reference was captured with that same clean build and is deterministic across independent runs.
- **Toolchain** — LLVM 14.0.0, Z3, gRPC 1.56.0, protobuf 23.1; pinned in `repro/motivating_example/Dockerfile`.
- The dynamic half of CLODS (runtime instrumentation agent + archived `[BM]` logs that select each round's deviation point) is not part of this component; the harness drives the recorded selections directly (`manualOverride: 1`). The IR-generation component (`components/ir-generation`) documents how the bitcode is produced.

## References

- CLODS paper (SOSP'26), §2 Motivating Example (HDFS-10453, Figure 1); §5 building blocks (CDA/DDA/CSA) + deviation types; Figures 5 & 7 algorithms.