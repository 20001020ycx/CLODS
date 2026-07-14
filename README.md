# CLODS — Artifact Review Index

CLODS is a multi-component artifact. Each subdirectory under `components/` is an independently reproducible piece of the pipeline. This README is the reviewer's index: it says what each component is, what to check, and where the detailed review steps live.

| Component | Status | Owner of review steps | What it produces |
|---|---|---|---|
| [`components/ir-generation`](components/ir-generation/README.md) | implemented | `components/ir-generation/README.md` | LLVM bitcode + readable LLVM IR from Java (hello-world and the Hadoop HDFS motivating example) |
| `components/static-analyzer` | in progress (separate contribution) | its own README (when added) | static analysis over the generated LLVM IR |
| `components/instrumenter` | pending | its own README (when added) | runtime instrumentation |
| `components/log-analyzer` | pending | its own README (when added) | log analysis |

Components are decoupled. A reviewer can evaluate `ir-generation` on its own without the others.

## How to review a component

For each implemented component:

1. **Read its README** — the authoritative, step-by-step reproduction instructions and expected outputs.
2. **Run the public scripts verbatim** — do not hand-edit the workflow; the scripts are the artifact.
3. **Check the recorded reference run** — each component README records a dated reference run (sizes, counts, timings). A reproduction should land in the same ballpark; exact byte-equality is not required where the README says so (e.g., Docker image IDs, `fNNN` assignments, and the Hadoop version difference for the motivating example).
4. **Inspect the provenance manifest** — every component that produces artifacts writes a `manifest.txt` (or equivalent) recording pinned revisions, modes, timings, and hashes. Verify the pins match the README.
5. **Run the verification step** — each component has a final verification script that fails loudly if a required artifact is missing/empty/undecodable. A clean exit is the pass signal.

## `components/ir-generation` — review checklist

Goal: compile Java to LLVM bitcode/IR with a pinned GraalVM Native Image LLVM backend, preserving a per-method `Java method -> fNNN` mapping so a specific method (`BlockPlacementPolicyDefault.chooseRandom`) can be located and disassembled. Detailed steps are in [`components/ir-generation/README.md`](components/ir-generation/README.md).

**Part 1 — hello-world (`SimpleMath.java` → LLVM IR):**
- `./build.sh && ./run.sh && ./generate-ir.sh` from `components/ir-generation/`.
- Pass signal: `generate-ir.sh` exits 0 and JVM/native outputs match exactly (`sumOfSquares(10) = 385`, `fibonacci(10) = 55`).
- Spot-check: `output/function2IRmapping.txt` contains `SimpleMath_fibonacci/main/sumOfSquares`, and the corresponding `output/fNNN.ll` files exist and are non-empty.

**Part 2 — motivating example (Hadoop HDFS `NameNode` → LLVM IR, comparable to `614good.bc`):**
- `cd components/ir-generation/hdfs && ./build.sh && ./run.sh && ./generate-hdfs-ir.sh`.
- Pass signal: `generate-hdfs-ir.sh` exits 0; `hdfs/output/hadoop-2.7.1-a4c88298/` contains `manifest.txt`, `namenode/namenode.monolithic.bc`, `namenode/chooseRandom.bc`, `namenode/chooseRandom.ll`, and `verification/comparison.txt`.
- Provenance: `manifest.txt` records `source_commit=a4c88298...`, `native_image_mode=compat`, pinned Graal/mx/JDK/protoc revisions, and native-image timing. Verify the commit matches the README.
- Comparison: `verification/comparison.txt` (present only if the historical `614good.bc` was available to mount) shows both modules are LLVM IR bitcode with the same `chooseRandom` symbol family (10 symbols each). Both are measured with the same pinned `llvm-nm`, so the counts are directly comparable. The modules are not byte-equal because the Hadoop source version differs (2.5.2 → 2.7.1) — this is expected, not a defect.
- Target-method check: `namenode/chooseRandom.ll` contains the paper's analysis entities (`countNumOfAvailableNodes`, `NotEnoughReplicasException`, `numOfReplicas`, `addIfIsGoodTarget`) with DWARF debug info pointing to `BlockPlacementPolicyDefault.java`.
- Known caveats (documented in the component README, not defects): strict mode cannot produce bitcode for this target (two JDK internals the pinned fork cannot represent), so the default is `compat`; the native `namenode` executable is produced but is not expected to run — the bitcode/IR is the deliverable.

## Repo layout

```text
clods/
  README.md                      this index
  components/
    ir-generation/               implemented — Java to LLVM IR (see its README)
    static-analyzer/            in progress (separate contribution; do not mix with ir-generation)
    instrumenter/               pending
    log-analyzer/               pending
```

Each component is self-contained: it brings its own Dockerfile(s), scripts, and metadata, and does not depend on the others at build or run time.