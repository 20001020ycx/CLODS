# CLODS - Static Analyzer

Backward control/data-flow + call-site analysis over a monolithic LLVM IR module: given the IR and a failure-relevant Java source location, emit an instrumentation plan that localizes the root cause. Reproduces the paper's motivating example, HDFS-10453 (CLODS, SOSP'26, §2 "Motivating Example").

Everything runs in Docker. No host LLVM, Z3, or protobuf is required. Requirements: Linux x86-64, Docker Engine, Git LFS, internet during image build, ~2 GB disk for the bitcode.

## 1) Reproduce the motivating example (HDFS-10453)

The analyzer is config-driven: `CLODS.conf` selects the IR module and the seed location (`BlockPlacementPolicyDefault.java:551`). The harness drives the five historically recorded manual-selection rounds and checks the captured plan against the reference. Steps (run from this directory):

```bash
out="$HOME/clods-static-analyzer-$(date +%Y%m%d-%H%M%S)"
bash repro/614good/reproduce-614good.sh --build-image --output "$out"
```

`--build-image` builds the pinned toolchain image (`repro/614good/Dockerfile`: LLVM 14.0.0, Z3, gRPC + `protoc` + `grpc_cpp_plugin`) once; omit it on later runs. The harness exports the tracked `StaticAnalysis/` source from `HEAD`, writes `CLODS.conf` pointing `IRFilePath` at the mounted `614good.bc`, compiles the analyzer, drives the rounds with `repro/614good/drive_rounds.py`, and compares against `reference/manifest.json`. The analyzer source in the checkout is never edited; evidence is written outside the repo. Runtime networking is disabled. ~3–4 min after the image is built (the 316 MB IR is parsed once).

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
diff "$d/session.log" repro/614good/reference/transcript-614good-ref.log  # byte-identical (deterministic)
```

The wrapper exits non-zero on any build failure, timeout, normalization failure, or semantic mismatch; exit `0` plus `match: true` is the reproduction criterion.

### Outputs

`$out/current/`:

```text
session.log                  full analyzer transcript (5 rounds)
driver-result.json           selections driven + outcome
reference-comparison.json    match result vs reference manifest
normalized-rules.json        per-round instrumentation rules
configure.log / build.log    from-source build logs
```

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

## Inputs & provenance

- **Bitcode** — `bytecode/614good.bc` (316,482,648 bytes; sha-256 `a0ca09ca4d4919ceffa29567ff723d2f941210d9de39503b9ac2741da5c1c2b6`), Git LFS (`.gitattributes`). Hydrate with `git lfs pull --include='components/static-analyzer/bytecode/614good.bc'` if your clone has a pointer.
- **Analyzer source** — `StaticAnalysis/`, ported from container `06865b433bbb:/home/ridevsot/StaticAnalysis` @ `222b486b`; protobuf schema vendored at `lib/ProtocBuf/bm_protobuf/instrumentation.proto` (no submodule).
- **Reference** — `repro/614good/reference/manifest.json` (recorded selections, expected rules, provenance) and `transcript-614good-ref.log` (canonical byte-identical transcript).
- **Toolchain** — LLVM 14.0.0, Z3, gRPC 1.56.0, protobuf 23.1; pinned in `repro/614good/Dockerfile`. A clean from-source build was verified to reproduce the reference byte-identically (see `manifest.json` → `analyzerProvenance.fromSourceBuildVerified`).
- The dynamic half of CLODS (runtime instrumentation agent + archived `[BM]` logs that select each round's deviation point) is not part of this component; the harness drives the recorded selections directly (`manualOverride: 1`). The IR-generation component (`components/ir-generation`) documents how the bitcode is produced.

## References

- CLODS paper (SOSP'26), §2 Motivating Example (HDFS-10453, Figure 1); §5 building blocks (CDA/DDA/CSA) + deviation types; Figures 5 & 7 algorithms
- Analyzer source origin: container `zk_1900_clods` (`06865b433bbb:/home/ridevsot/StaticAnalysis`), revision `222b486b3850b7a9d098a26a93760e6cee72db68`