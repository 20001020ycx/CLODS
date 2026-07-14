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

This targets the paper's motivating example — **HDFS-10453**, analyzed in CLODS (SOSP'26) §2 "Motivating Example", Figure 1 (`/home/ycx/research/papers/sosp26-paper1972 (1).pdf`). The paper analyzes `chooseRandom`, which selects replication targets and throws `NotEnoughReplicasException`, together with its callees `isGoodTarget` and `getNumAvailableNodes` and the replica counter `nReplicate`.

**What we check:** that the generated LLVM IR of `chooseRandom` contains the functions the paper discusses — i.e. they compiled through to real LLVM IR symbols/calls, with DWARF debug info tying them back to `BlockPlacementPolicyDefault.java`. No native binary run is needed; the deliverable is the IR, and the check is a grep over it.

The paper's Figure 1 pseudocode names map to the actual Hadoop 2.7.1 names that appear in the IR:

| Paper (Fig. 1) | Hadoop 2.7.1 / IR token |
|---|---|
| `chooseRandom` | `chooseRandom` |
| `isGoodTarget` | `addIfIsGoodTarget` |
| `getNumAvailableNodes` | `countNumOfAvailableNodes` |
| `nReplicate` | `numOfReplicas` |
| `NotEnoughReplicasException` | `NotEnoughReplicasException` |

After running the workflow, confirm the entities are present in the disassembled IR:

```bash
cd hdfs/output/hadoop-2.7.1-a4c88298/namenode
for e in chooseRandom addIfIsGoodTarget countNumOfAvailableNodes NotEnoughReplicasException numOfReplicas BlockPlacementPolicyDefault.java; do
  printf '%-32s %s\n' "$e" "$(grep -cF "$e" chooseRandom.ll)"
done
# expected (all > 0):
#   chooseRandom                     45
#   addIfIsGoodTarget                3
#   countNumOfAvailableNodes         3
#   NotEnoughReplicasException       3
#   numOfReplicas                    3
#   BlockPlacementPolicyDefault.java 1
grep -nF 'addIfIsGoodTarget' chooseRandom.ll | head -1            # the good-target call
grep -nF 'NotEnoughReplicasException' chooseRandom.ll | head -1   # the thrown exception
grep -nF 'BlockPlacementPolicyDefault.java' chooseRandom.ll | head -1  # DWARF source location
```

`verify-artifacts.sh` runs this presence check automatically and writes `verification/motivating-example.txt` (one line per entity: IR token, paper name, description, match count, first matching line); it fails if any entity is missing.

### Reproducing it

Compiles `org.apache.hadoop.hdfs.server.namenode.NameNode` from the paper's Hadoop 2.7.1 source and extracts `BlockPlacementPolicyDefault.chooseRandom` (the `int numOfReplicas` overload at `BlockPlacementPolicyDefault.java:613`). The monolithic bitcode is comparable in purpose to the historical reference `614good.bc`.

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
1. `container/build-hadoop.sh` — revision gate (commit, clean tree, version 2.7.1, required source files), copy source to a writable volume, `mvn install`, stage the compile-scope classpath, `javap` + JVM `NameNode --help` as a classpath sanity check.
2. `container/generate-native-image.sh` — `mx native-image -H:Class=NameNode -H:CompilerBackend=llvm -H:LLVMMaxFunctionsPerBatch=0 ...` with inlining disabled, `-O0 -g`; preserves the batch bitcode as `namenode.monolithic.bc`, locates `chooseRandom` via the mapping (largest compiled overload), disassembles it to `chooseRandom.ll`, and parses native-image's timing summary into the manifest.
3. `container/verify-artifacts.sh` — runs the motivating-example presence check, decodes the bitcode, compares symbol counts against `614good.bc` (if mounted), and writes checksums.

Outputs land in `hdfs/output/hadoop-2.7.1-a4c88298/`:

```text
manifest.txt                         provenance, mode, timing, symbol counts
classpath.txt / classpath.sha256     staged compile-scope classpath
namenode/namenode.monolithic.bc      broad LLVM bitcode — comparable to 614good.bc
namenode/function2IRmapping.txt      Java method -> fNNN mapping
namenode/chooseRandom.bc / .ll       the paper's target method (the check runs on the .ll)
verification/motivating-example.txt  paper-entity presence report (the core check)
verification/comparison.txt          this vs reference symbol-count table
```


## References

- CLODS paper (SOSP'26), §2 Motivating Example (HDFS-10453, Figure 1): `/home/ycx/research/papers/sosp26-paper1972 (1).pdf`
- GraalVM LLVM Backend for Native Image: <https://www.graalvm.org/22.0/reference-manual/native-image/LLVMBackend/>
- Research fork (`android_IR`): <https://github.com/rishikeshdevsot/graal/commits/android_IR/>
- Pinned commit: <https://github.com/rishikeshdevsot/graal/commit/ec486f0f2bc598d3212b62a8d05a10b6d07dea92>
