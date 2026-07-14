# ir-generation

Compile Java programs to LLVM bitcode and readable LLVM IR using the LLVM backend of a pinned research fork of GraalVM Native Image (`rishikeshdevsot/graal`, branch lineage `android_IR`, commit `ec486f0f`). The fork's `-H:DumpLLVMStackMap` emits a `Java method -> fNNN` mapping, so individual methods can be located in the per-function `fNNN.bc` bitcode and disassembled to `.ll`.

This component is self-contained and does not touch the sibling `static-analyzer`, `instrumenter`, or `log-analyzer` components.

Everything runs in Docker. No host JDK, GraalVM, LLVM, Maven, or Python is required. Requirements: Linux x86-64, Docker Engine, internet during image build, ~15 GB disk, ~8 GB RAM.

## 1) Hello-world Java program → LLVM IR

The example is `SimpleMath.java` in this directory. Steps (run from this directory):

```bash
./build.sh          # build the base image (pinned graal + LLVM toolchain; slow, ~2-3 min cached)
./run.sh            # start the container; this dir is mounted at /workspace
./generate-ir.sh    # compile SimpleMath, run JVM + native, emit bitcode + IR
```

`generate-ir.sh` runs `javac` → JVM run → `mx native-image -H:CompilerBackend=llvm` → native run → output diff → locate `SimpleMath` in the mapping → disassemble each mapped `.bc` to `.ll`.

Outputs land in `output/`:

```text
output/simple-math                         native executable
output/function2IRmapping.txt              Java method -> fNNN mapping
output/simple-math-functions.txt           SimpleMath entries from the mapping
output/native-image-tmp/SVM-<id>/llvm/fNNN.bc   per-method LLVM bitcode
output/fNNN.ll                             readable LLVM IR for SimpleMath methods
```

Inspect:

```bash
cat output/simple-math-functions.txt        # e.g. SimpleMath_fibonacci -> f0
less output/f0.ll                            # fibonacci IR
./output/simple-math 10                     # sumOfSquares(10) = 385, fibonacci(10) = 55
```

Reference run (2026-07-13): JVM and native output matched exactly; `f0.bc`=fibonacci, `f1.bc`=main, `f2.bc`=sumOfSquares; warm repeat ~71 s, native-image peak ~3.9 GB.

## 2) Motivating example (Hadoop HDFS NameNode) → LLVM IR

Compiles `org.apache.hadoop.hdfs.server.namenode.NameNode` from the paper's Hadoop 2.7.1 source and extracts `BlockPlacementPolicyDefault.chooseRandom` (the `int numOfReplicas` overload at `BlockPlacementPolicyDefault.java:613`). The resulting monolithic bitcode is comparable in purpose to the historical reference `614good.bc`.

Defaults (overridable via environment, defined in `hdfs/shared_vars.sh`):

```text
HADOOP_SOURCE       =/home/ycx/research/bug/MotivatingExample   # read-only mount; must be a git checkout at the pinned commit
HADOOP_COMMIT       =a4c88298d2439782b49b53e470c03a96e24773d6
HADOOP_VERSION      =2.7.1
HADOOP_REFERENCE_BC =/home/ycx/research/BlameMaster/StaticAnalyisLLVM/bytecode/614good.bc   # optional; mounted read-only for the comparison table
```

Steps (run from this directory):

```bash
./build.sh                          # base image (section 1) must exist first
cd hdfs
./build.sh                          # derived image: adds Maven 3.6.3 + protoc 2.5.0
./run.sh                            # mount Hadoop source read-only at /input/hadoop
./generate-hdfs-ir.sh               # build Hadoop, native-image NameNode, extract chooseRandom, verify
```

`generate-hdfs-ir.sh` does three things:
1. `container/build-hadoop.sh` — revision gate (commit, clean tree, version 2.7.1, required source files), copy source to a writable volume, `mvn install`, stage the compile-scope classpath, `javap` + JVM `NameNode --help` as a safe surface check.
2. `container/generate-native-image.sh` — `mx native-image -H:Class=NameNode -H:CompilerBackend=llvm -H:LLVMMaxFunctionsPerBatch=0 ...` with inlining disabled, `-O0 -g`; preserves the batch bitcode as `namenode.monolithic.bc`, locates `chooseRandom` via the mapping (largest compiled overload), disassembles it to `chooseRandom.ll`, and parses native-image's timing summary into the manifest.
3. `container/verify-artifacts.sh` — validates artifacts, decodes bitcode, compares symbol counts against `614good.bc` (if mounted), writes checksums.

Outputs land in `hdfs/output/hadoop-2.7.1-a4c88298/`:

```text
manifest.txt                         provenance, mode, timing, symbol counts
classpath.txt / classpath.sha256     staged compile-scope classpath
namenode/namenode                    native executable (produced; not required to run)
namenode/namenode.monolithic.bc      broad LLVM bitcode — comparable to 614good.bc
namenode/function2IRmapping.txt      Java method -> fNNN mapping
namenode/chooseRandom.bc / .ll       the paper's target method
verification/comparison.txt          this vs reference symbol-count table
verification/jvm-namenode-help.txt   JVM NameNode usage (safe surface check)
```

Reference run (2026-07-13, compat mode):

| Metric | `614good.bc` (Hadoop 2.5.2) | `namenode.monolithic.bc` (Hadoop 2.7.1) |
|---|---|---|
| Type | LLVM IR bitcode | LLVM IR bitcode |
| Size | 316,482,648 B | 364,702,616 B |
| Defined symbols (`llvm-nm`) | 63,605 | 66,853 |
| `chooseRandom` symbols | 10 | 10 |

Both modules share the same Graal symbol family for `chooseRandom` (method + `_equals_`/`_hashCode_`/`_invoke_` accessors); per-method hashes differ only because the Hadoop version differs (2.5.2 → 2.7.1). `chooseRandom.ll` contains the paper's analysis targets (`countNumOfAvailableNodes`, `NotEnoughReplicasException`, `numOfReplicas`, `addIfIsGoodTarget`) with DWARF debug info pointing to `BlockPlacementPolicyDefault.java`.

### Notes / caveats

- **Mode.** The default is `compat` (`--allow-incomplete-classpath --report-unsupported-elements-at-runtime`), the mode that produces the bitcode. Strict mode (`HDFS_NATIVE_IMAGE_MODE=strict ./generate-hdfs-ir.sh`, `--no-fallback`) fails for this target because the pinned fork cannot represent two JDK internals (`ClassLoader.resolveClass0`, `URLClassPath.getLookupCacheForClassLoader`) reached via Jetty/SSL — the same situation the original recipe solved with the compat flags. `manifest.txt` records `native_image_mode`.
- **Deliverable is the bitcode/IR, not a runnable daemon.** The native `namenode` is produced (~295 MB) but `--help` throws `NoClassDefFoundError` under incomplete-classpath. The `.bc`/`.ll` are generated regardless; JVM `NameNode --help` remains the safe behavioural check.
- **Base image identity.** Docker image IDs are not bit-identical across hosts, so `hdfs/build.sh` only checks the base image *exists* by default. Set `BASE_IMAGE_ID` in `hdfs/shared_vars.sh` to enforce a specific verified base.
- **Reproducibility of the comparison.** Both bitcode modules are measured with the same pinned Graal `llvm-nm`, so the counts in `comparison.txt` are directly comparable. `614good.bc` itself is not regenerated here; it is treated as an external reference and is only needed for the comparison table.

## Review checklist

A successful review confirms, without editing the scripts:

**Hello-world (section 1):** `generate-ir.sh` exits 0; JVM and native output match exactly (`sumOfSquares(10) = 385`, `fibonacci(10) = 55`); `output/function2IRmapping.txt` lists `SimpleMath_fibonacci`/`main`/`sumOfSquares` and the mapped `output/fNNN.ll` files are non-empty.

**Motivating example (section 2):** `generate-hdfs-ir.sh` exits 0; `hdfs/output/hadoop-2.7.1-a4c88298/` contains `manifest.txt`, `namenode/namenode.monolithic.bc`, `namenode/chooseRandom.bc`, `namenode/chooseRandom.ll`, and `verification/comparison.txt`; `manifest.txt` records `source_commit=a4c88298...` and `native_image_mode=compat`; `chooseRandom.ll` contains `countNumOfAvailableNodes`, `NotEnoughReplicasException`, `numOfReplicas`, and `addIfIsGoodTarget` with DWARF info pointing to `BlockPlacementPolicyDefault.java`.

The bitcode is not expected to be byte-identical to `614good.bc` (different Hadoop version); the comparison table shows the same `chooseRandom` symbol family and comparable symbol counts, both measured with the same pinned `llvm-nm`. See "Notes / caveats" above for the strict/compat and runnable-executable caveats.

## Container management

```bash
./attach.sh   # interactive shell in the running container
./delete.sh   # stop and remove the container
# hdfs only:
cd hdfs && ./delete.sh
DELETE_HDFS_WORK_VOLUME=1 ./delete.sh   # also remove the Maven work volume
```

## References

- GraalVM LLVM Backend for Native Image: <https://www.graalvm.org/22.0/reference-manual/native-image/LLVMBackend/>
- Research fork (`android_IR`): <https://github.com/rishikeshdevsot/graal/commits/android_IR/>
- Pinned commit: <https://github.com/rishikeshdevsot/graal/commit/ec486f0f2bc598d3212b62a8d05a10b6d07dea92>