# CLODS - Static Analyzer

Backward control/data-flow + call-site analysis over a monolithic LLVM IR module: given the IR and a failure-relevant Java source location, emit an instrumentation plan that localizes the root cause. Reproduces the paper's motivating example, HDFS-10453 (CLODS, SOSP'26, §2 "Motivating Example").

Everything runs in Docker. No host LLVM, Z3, or protobuf is required. Requirements: Linux x86-64, Docker Engine, Git LFS, internet during image build, ~2 GB disk for the bitcode.

The analyzer consumes a pinned pre-compiled module, `bytecode/motivating_example_full.bc` (316 MB, Git LFS), so the emitted plan is reproducible. Pull it with `git lfs pull --include='components/static-analyzer/bytecode/motivating_example_full.bc'`. To inspect the IR, disassemble on demand (do not commit the ~1.6 GB output): `llvm-dis bytecode/motivating_example_full.bc -o motivating_example_full.ll`.

> **Determinism note.** LLVM IR generation (the `ir-generation` component) may reorder functions across runs/versions, which would change the analyzer's plan numbering. The static analyzer therefore consumes the pinned pre-compiled module above rather than regenerating IR.

## 1) Reproduce and what to check

Steps (run from this directory):

```bash
out="$HOME/clods-static-analyzer-$(date +%Y%m%d-%H%M%S)"
bash repro/motivating_example/reproduce.sh --build-image --output "$out"
```

`--build-image` builds the pinned toolchain image (`repro/motivating_example/Dockerfile`: LLVM 14.0.0, Z3, gRPC + `protoc` + `grpc_cpp_plugin`) once; omit it on later runs. The harness exports the tracked `StaticAnalysis/` source from `HEAD`, compiles it, drives the recorded selections, and captures the transcript. Runtime networking is disabled. Expect ~4 min after the image is built (the 316 MB IR is parsed once).

**What the analyzer finds.** Starting from the symptom location (`BlockPlacementPolicyDefault.java:551`), the analysis walks backward and reaches the root cause — the delete thread's write of `b.size`. It traces `b.size` to its writer (`Block.setNumBytes`, the `numBytes` field store at `Block.java:137`) and then to the call site that passes `Long.MAX_VALUE` as the argument, identifying it as a constant:

```text
Caller inst is:   %10 = call { i64 } @Block_setNumBytes_...(i64 %0, i8 addrspace(1)* %2, i64 9223372036854775807)
Caller argument is: i64 9223372036854775807
...
Constant value: i64 9223372036854775807
```

`9223372036854775807` is `Long.MAX_VALUE` (`0x7FFFFFFFFFFFFFFF`) — the value the edit-log replay path (`FSEditLogLoader`) stores into `b.size` via `Block.setNumBytes`. Reaching a constant is the data-flow **stopping condition**: a constant has no further definition to trace, so the analysis terminates there. That constant is the root cause of HDFS-10453: with `b.size = Long.MAX_VALUE`, `isGoodTarget` always returns false and replication never succeeds.

**What to check.** The output event is `$out/current/driver-result.json`:

```bash
d="$out/current"
cat "$d/driver-result.json"
grep "Constant value: i64 9223372036854775807" "$d/session.log"     # the root-cause constant is reached
cat "$d/reference-comparison.json"                                   # {"match": true, ...}
diff "$d/session.log" repro/motivating_example/reference/transcript-motivating-example-ref.log  # byte-identical
```

- `completedSelectionCount == expectedSelectionCount` — all recorded selections (the plan picks plus the two "no divergence" answers that continue the data flow) were replayed; `completedSelections` lists them.
- `childReturnCode` is negative (e.g. `-2` = killed by SIGINT) — the driver stopped the analyzer at the next prompt once the recorded input ran out; it did **not** crash and did **not** invent selections beyond the recording.
- `match: true` and `session.log` is byte-identical to the reference transcript.

The wrapper exits non-zero on any build failure, timeout, normalization failure, or semantic mismatch; exit `0` plus `match: true` is the reproduction criterion.

## 2) How the output correlates to the paper

The tool emits a backward chain of analysis steps on the real IR (real source lines + bytecode indexes, captured in `reference/manifest.json`); the paper presents the same example on abridged pseudocode. Building blocks (paper §5): **CDA** (control dependency → CBIs), **DDA** (data dependency → definitions), **CSA** (call sites → callers); deviation types: **location** vs **branch**.

| Analysis step | What it finds | Paper step | Building block |
|---|---|---|---|
| CDA from the symptom | `if nReplicate>0` (line 17) | symptom (line 18) is a location deviation | Location + CDA |
| DDA on the replication flag | def line 14 + CBIs 13/11/9 | branch deviation at line 17 | Branch + DDA |
| DDA into the target predicate | `isGoodTarget` predicates (lines 22/23) | branch deviation at line 13 | Branch + DDA |
| DDA + CSA at the line-23 fork | `blockSize` (arg) → callers; `node.getRemaining()` → field writers | line-23 predicate forks | Branch + DDA + CSA |
| CSA up the caller chain | toward `chooseRandom(b.numReplicas, b.size)` → `b.size` | line 4 | CSA |
| DDA to the `b.size` writer | `Block.setNumBytes`, `numBytes` field store (`Block.java:137`) | the `b.size` writer | DDA → field writer |
| DDA to the stored value | `Long.MAX_VALUE` (`9223372036854775807`) — a constant → stop | root cause | Constant → stop |

The final step is the stopping condition: the data-flow analysis terminates at the constant `Long.MAX_VALUE`, the value written into `b.size` by the edit-log replay path — the data race at the root of HDFS-10453. (The exact number of emitted steps is an implementation detail of the current analyzer and may change with optimization; the reproduction checks the final outcome — the constant is reached and the transcript matches the reference — not a fixed step count.)

## References

- CLODS paper (SOSP'26), §2 Motivating Example (HDFS-10453, Figure 1); §5 building blocks (CDA/DDA/CSA) + deviation types; Figures 5 & 7 algorithms.