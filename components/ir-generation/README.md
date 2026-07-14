# LLVM IR Generation

Compile interpreted (Java/Kotlin) programs to LLVM bitcode and readable LLVM IR using the LLVM backend of a pinned research fork of GraalVM Native Image (`rishikeshdevsot/graal`, branch lineage `android_IR`, commit `ec486f0f`). The fork's `-H:DumpLLVMStackMap` emits a `Java method -> fNNN` mapping, so individual methods can be located in the per-function `fNNN.bc` bitcode and disassembled to `.ll`.

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
less output/f0.ll  # fibonacci IR
less output/f1.ll  # main IR
less output/f2.ll  # sumOfSquares IR
```

## 2) Motivating example (Hadoop HDFS NameNode) → LLVM IR

Targets the paper's motivating example, HDFS-10453 (CLODS, SOSP'26, §2 "Motivating Example"): `chooseRandom`, which selects replication targets and throws `NotEnoughReplicasException`, with callees `isGoodTarget` and `getNumAvailableNodes` and the replica counter `nReplicate`. The monolithic bitcode is comparable in purpose to the historical reference `614good.bc`.

### Steps

```bash
./build.sh          # base image from section 1 must exist first
cd hdfs
./build.sh          # derived image: Maven 3.6.3 + protoc 2.5.0
./run.sh            # mount Hadoop source read-only at /input/hadoop
./generate-hdfs-ir.sh
```

Defaults (overridable via env in `hdfs/shared_vars.sh`):

```text
HADOOP_SOURCE       =/home/ycx/research/bug/MotivatingExample   # git checkout at the pinned commit (read-only mount)
HADOOP_COMMIT       =a4c88298d2439782b49b53e470c03a96e24773d6
HADOOP_VERSION      =2.7.1
HADOOP_REFERENCE_BC =/home/ycx/research/BlameMaster/StaticAnalyisLLVM/bytecode/614good.bc   # optional, for the symbol-count comparison
```

### What to check

The IR of `chooseRandom` must contain the functions the paper analyzes, as real LLVM IR symbols/calls with DWARF info tying them to `BlockPlacementPolicyDefault.java`. Paper Figure 1 names → Hadoop 2.7.1 IR tokens:

| Paper (Fig. 1) | IR token |
|---|---|
| `chooseRandom` | `chooseRandom` |
| `isGoodTarget` | `addIfIsGoodTarget` |
| `getNumAvailableNodes` | `countNumOfAvailableNodes` |
| `nReplicate` | `numOfReplicas` |
| `NotEnoughReplicasException` | `NotEnoughReplicasException` |

```bash
cd hdfs/output/hadoop-2.7.1-a4c88298/namenode
for e in chooseRandom addIfIsGoodTarget countNumOfAvailableNodes NotEnoughReplicasException numOfReplicas BlockPlacementPolicyDefault.java; do
  printf '%-32s %s\n' "$e" "$(grep -cF "$e" chooseRandom.ll)"
done
# every count must be > 0
```

`generate-hdfs-ir.sh` runs this check automatically and writes `verification/motivating-example.txt`; it fails if any entity is missing.

### Outputs

`hdfs/output/hadoop-2.7.1-a4c88298/`:

```text
manifest.txt                         provenance, mode, timing, symbol counts
namenode/namenode.monolithic.bc      broad LLVM bitcode — comparable to 614good.bc
namenode/chooseRandom.bc / .ll       the paper's target method (check runs on the .ll)
verification/motivating-example.txt  paper-entity presence report (the check)
verification/comparison.txt          this vs reference symbol-count table
```

## References

- CLODS paper (SOSP'26), §2 Motivating Example (HDFS-10453, Figure 1): `/home/ycx/research/papers/sosp26-paper1972 (1).pdf`
- GraalVM LLVM Backend for Native Image: <https://www.graalvm.org/22.0/reference-manual/native-image/LLVMBackend/>
- Research fork (`android_IR`): <https://github.com/rishikeshdevsot/graal/commits/android_IR/>
- Pinned commit: <https://github.com/rishikeshdevsot/graal/commit/ec486f0f2bc598d3212b62a8d05a10b6d07dea92>