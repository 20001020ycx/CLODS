# CLODS - Static Analyzer

Backward control/data-flow + call-site analysis over a monolithic LLVM IR module: given the IR and a failure-relevant Java source location, emit an instrumentation plan that localizes the root cause. Reproduces the paper's motivating example, HDFS-10453 (CLODS, SOSP'26, §2 "Motivating Example").

Everything runs in Docker. No host LLVM, Z3, or protobuf is required. Requirements: Linux x86-64, Docker Engine, Git LFS, internet during image build.

Two interchangeable IR modules produce **byte-identical** analyzer output — use either:
- `bytecode/motivating_example_full.bc` (316 MB) — the full module (default).
- `bytecode/motivating_example_fast.bc` (33 MB) — abridged, ~10× faster to parse, same output.

> **Determinism note.** LLVM IR generation (the `ir-generation` component) may reorder functions across runs/versions, which would change the analyzer's plan numbering. The static analyzer therefore consumes pinned pre-compiled modules (Git LFS) so the plan is reproducible. Pull with `git lfs pull --include='components/static-analyzer/bytecode/*.bc'`. To inspect the IR, disassemble on demand (do not commit the ~1.6 GB output): `llvm-dis bytecode/motivating_example_full.bc -o motivating_example_full.ll`.

## 1) Reproduce and what to check

Steps (run from this directory):

```bash
out="$HOME/clods-static-analyzer-$(date +%Y%m%d-%H%M%S)"
bash repro/motivating_example/reproduce.sh --build-image --output "$out"          # full 316 MB module
# or:  bash repro/motivating_example/reproduce.sh --fast --build-image --output "$out"   # 33 MB, same output
```

**What the analyzer finds.** Starting from the symptom location (`BlockPlacementPolicyDefault.java:551`), the analysis walks seven rounds backward and reaches the root cause — the delete thread's write of `b.size`. The final round traces the callers of `Block.setNumBytes` (the `b.size` writer) and finds the call site that passes `Long.MAX_VALUE` as the argument, identifying it as a constant:

```text
Caller inst is:   %10 = call { i64 } @Block_setNumBytes_...(i64 %0, i8 addrspace(1)* %2, i64 9223372036854775807)
Caller argument is: i64 9223372036854775807
...
ID: 1
Constant value: i64 9223372036854775807
```

`9223372036854775807` is `Long.MAX_VALUE` (`0x7FFFFFFFFFFFFFFF`) — the value the deletion thread stores into `b.size` via `setBlockSize(Long.MAX_VALUE)`. Reaching a constant is the data-flow **stopping condition**: a constant has no further definition to trace, so the analysis terminates there. That constant is the root cause of HDFS-10453: with `b.size = Long.MAX_VALUE`, `isGoodTarget` always returns false and replication never succeeds.



## References

- CLODS paper (SOSP'26), §2 Motivating Example (HDFS-10453, Figure 1); §5 building blocks (CDA/DDA/CSA) + deviation types; Figures 5 & 7 algorithms.