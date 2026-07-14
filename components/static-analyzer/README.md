# CLODS static analyzer — artifact review

This component is the **static analyzer** of CLODS (SOSP '26 submission "paper
1972"; Rishikesh Devsot, MAS thesis, 2024). It takes a monolithic LLVM IR
module produced by the IR-generation component and a failure-relevant Java
source location, and emits an instrumentation plan that localizes the root
cause of HDFS-10453. This README is the reviewer entry point: it shows how to
reproduce the motivating example and explains each reproduced round in the
paper's own terms.

## 1. Reproduce

Prerequisites: Docker, and the Git-LFS bitcode `bytecode/614good.bc`
(hydrated automatically on `git clone` once LFS is enabled; see §5).

```bash
cd components/static-analyzer
out="$HOME/clods-static-analyzer-$(date +%Y%m%d-%H%M%S)"
bash repro/614good/reproduce-614good.sh --build-image --output "$out"
```

`--build-image` builds the pinned toolchain image
(`repro/614good/Dockerfile`: LLVM 14.0.0, Z3, gRPC + `protoc` +
`grpc_cpp_plugin`) once; subsequent runs omit it. The harness then exports the
tracked `StaticAnalysis/` source from the component `HEAD`, writes a
`CLODS.conf` pointing `IRFilePath` at the mounted `614good.bc`, compiles the
analyzer in the toolchain image, drives the five recorded manual-selection
rounds with `repro/614good/drive_rounds.py`, and checks the captured plan
against `repro/614good/reference/manifest.json`. The analyzer source in the
checkout is never edited; all evidence is written outside the repository.
Runtime container networking is disabled. The run takes ~3–4 minutes after
the image is built (the 316 MB IR is parsed once per run).

**Expected outcome** (exit code `0`):

```
Reproduction evidence: …/current
Outcome: incomplete-unrecorded-divergence-input
Detail: The next required input was an undocumented divergence answer.
```

`incomplete-unrecorded-divergence-input` is the *intended* success: all six
recorded decisions were driven and all five plans matched the reference, then
the driver stopped at the `Was there a divergence point?` prompt that the
historical note never answers — it does **not** invent a Round 6.

**Check the result:**

```bash
d="$out/current"
cat "$d/driver-result.json"        # completedSelectionCount == expectedSelectionCount == 6
cat "$d/reference-comparison.json" # {"match": true, "matchedRounds": [1,2,3,4,5], "mismatches": []}
```

The wrapper exits non-zero on any build failure, timeout, normalization
failure, or semantic mismatch; exit `0` plus `match: true` is the
reproduction criterion. The full analyzer transcript is `$d/session.log`.
For a byte-level check, `diff` it against the canonical
`repro/614good/reference/transcript-614good-ref.log` (the analyzer output is
byte-identical across independent runs — determinism verified).

## 2. How CLODS analyzes — the paper's framing

CLODS localizes a root cause by alternating static analysis of the LLVM IR
with runtime log comparison, in **rounds** (paper §3):

> "In each round, CLODS analyzes the IR and the logs to infer why the failure
> and the non-failure executions deviate at event `e_deviate`. Initially,
> `e_deviate` is the symptom event. Whenever CLODS's static analysis sees more
> than one possibility and the logs does not provide sufficient evidence … it
> will pause the analysis, instrument the program, and wait for the failure to
> occur again."

Each round takes `e_deviate` and produces an **instrumentation plan**; the Log
Analyzer returns the plan ID at which the two executions diverged, which
becomes `e_deviate` for the next round. Two **deviation types** (paper §5):

- **Location deviation** — `e_deviate` occurs in one execution but not the other.
- **Branch deviation** — a conditional branch present in both executions takes
  different targets.

Three **building blocks** (paper §5):

- **CDA** (Control Dependency Analysis) — the controlling branch instructions
  (CBIs) of `I`: branches that dominate `I` but `I` does not post-dominate them.
- **DDA** (Data Dependency Analysis) — instructions that could define a
  variable (local, function return, or shared variable).
- **CSA** (Call Site Analysis) — the call instruction(s) in the caller of the
  function containing `I`.

Two algorithms drive the rounds (paper Figures 5 and 7):

```text
LocationDeviationAnalysis(I):        BranchDeviationAnalysis(I):
  q = [I]                               for var in BranchCondition(I):
  while q not empty:                      writeSet = DDA(var)
    I = dequeue(q)                        plan.add(writeSet)
    CBIset = CDA(I)                       for W in writeSet:
    if CBIset: plan.add(CBIset)             LocationDeviationAnalysis(W)
    else: for C in CSA(I): q.enqueue(C)
```

The paper's abridged HDFS-10453 code (Figure 1), with the lines the rounds reach:

```text
4    chooseRandom(b.numReplicas, b.size)          # b.size flows in as blockSize
9    while nReplicate > 0 and nAvailable > 0:
11     if excludedNodes.add(chosenNode):
13     if isGoodTarget(blockSize, chosenNode):    # the gate that decrements nReplicate
14       nReplicate--
17   if nReplicate > 0:
18     throw NotEnoughReplicasException()          # symptom  (e_deviate, round 0)
23   else if (blockSize > node.getRemaining())      # isGoodTarget predicate
30 b.setBlockSize(Long.MAX_VALUE)                  # deletion-thread write (root cause)
```

## 3. The reproduced rounds, mapped to the paper

The tool emits five concrete rounds on the real 316 MB IR (real source lines
and bytecode indexes, captured in `reference/manifest.json`); the paper
presents the same example on abridged pseudocode. The mapping below pairs each
round with the paper step that produces it.

| Round | Tool selection | Paper step | Building block / deviation |
|---|---|---|---|
| 1 | `chooseRandom` **ID 1** (line 528) | symptom (line 18) is a location deviation → CDA returns `if nReplicate>0` (line 17) as the CBI | Location + CDA |
| 2 | `addIfIsGoodTarget` **ID 0** (line 571) | branch deviation at line 17 → DDA on `nReplicate` → definition line 14 + CBIs 13/11/9; logs pin deviation at line 13 | Branch + DDA |
| 3 | `isGoodTarget` **ID 3** (line 642) | branch deviation at line 13 → DDA on `isGoodTarget`'s return → predicates lines 22/23 | Branch + DDA |
| 4 | **branch 0, ID 3** (`chooseTarget`, line 305) | line-23 predicate forks: DDA on `blockSize` (arg) → CSA → callers (branch 0); DDA on `node.getRemaining()` (shared) → field writers (branches 1/2) | Branch + DDA + CSA |
| 5 | `BlockManager.chooseTargets` **ID 0** (line 3518) | CSA up the caller chain toward `chooseRandom(b.numReplicas, b.size)` (line 4) → `b.size` | CSA → termination |

**Round 1.** The symptom (`NotEnoughReplicasException`) is a location
deviation: it occurs in the failure run only. `LocationDeviationAnalysis` runs
**CDA** on the symptom; the sole CBI is `if (nReplicate > 0)` (paper line 17,
tool line 528), added to the plan. The tool's **ID 1** is this branch. The Log
Analyzer then reports a **branch deviation** at line 17, seeding Round 2.

**Round 2.** `BranchDeviationAnalysis` on the line-17 branch runs **DDA** on
`nReplicate`, returning its definition `nReplicate--` (line 14); line 14 is
added with its CBIs at lines 13, 11, 9 (paper §5). The logs localize the
deviation to **line 13** — the `if isGoodTarget(...)` gate (paper Figure 3).
The tool lands in `addIfIsGoodTarget` (line 571), the IR location of that gate.

**Round 3.** With a branch deviation at line 13, DDA follows the condition —
the return value of `isGoodTarget` — into the `isGoodTarget` body and its
predicates: `node.getStorageState() == READ_ONLY` (line 22) and
`blockSize > node.getRemaining()` (line 23). The tool's 18-ID `isGoodTarget`
plan enumerates these predicates concretely; **ID 3** (line 642) is the
predicate the logs identify as the deviation.

**Round 4.** The line-23 predicate depends on `blockSize` (a function
argument) and `node.getRemaining()` (a shared field). DDA forks: on `blockSize`
it crosses to callers via **CSA** (the tool's branch 0: `chooseTarget`,
`chooseRemoteRack`, stack-trace-scoped at `chooseRandom`); on
`node.getRemaining()` it searches all writers of the shared variable (the
tool's branch 1: `DatanodeDescriptor`/`rollBlocksScheduled`, and branch 2:
`DatanodeInfo`/`setRemaining`). Selecting **branch 0, ID 3** follows
`blockSize` upward through `chooseTarget`.

**Round 5.** CSA continues up the caller chain — `chooseTarget` →
`BlockManager.chooseTargets` (tool line 3518) — following `blockSize` to where
it originates: `chooseRandom(b.numReplicas, b.size)` (paper line 4), i.e. the
block's `b.size`.

## 4. Where the reproduction stops, and the root cause it heads toward

After Round 5 the analyzer asks `Was there a divergence point?`. The
historical note records Rounds 1–5 only — no Round 6 plan, no answer to that
prompt — so the driver stops here and reports
`incomplete-unrecorded-divergence-input`.

In the paper's terms, the next rounds would run DDA on `b.size`, finding two
competing writes in **two different threads**: the deletion thread's
`b.setBlockSize(Long.MAX_VALUE)` (line 30) and the block constructor's
`INIT_SIZE`. Paper §2 states the consequence: if the replication thread calls
`chooseRandom` on this block between lines 30 and 31, "`isGoodTarget` always
returns false because the test will always fail at line 23 … even on a system
with healthy storage." That **data race on `b.size`** is the root cause of
HDFS-10453. The five reproduced rounds carry the analysis exactly as far as
the historical transcript documents; the destination they trace toward is this
root-cause data race.

## 5. Inputs, provenance, and reference data

- **Bitcode** — `bytecode/614good.bc` (316,482,648 bytes; SHA-256
  `a0ca09ca4d4919ceffa29567ff723d2f941210d9de39503b9ac2741da5c1c2b6`),
  tracked via Git LFS (see `.gitattributes`). Hydrate with
  `git lfs pull --include='components/static-analyzer/bytecode/614good.bc'`
  if your clone has an LFS pointer instead of the real file.
- **Analyzer source** — `StaticAnalysis/`, the config-driven refactor ported
  from the canonical build at container `zk_1900_clods`
  (`06865b433bbb:/home/ridevsot/StaticAnalysis`), source revision
  `222b486b3850b7a9d098a26a93760e6cee72db68`. The protobuf schema is vendored
  at `StaticAnalysis/lib/ProtocBuf/bm_protobuf/instrumentation.proto` (plain
  files, no submodule).
- **Reference** — `repro/614good/reference/manifest.json` holds the recorded
  selections, the expected rules per round (captured from the analyzer above),
  and the analyzer/toolchain provenance. `reference/transcript-614good-ref.log`
  is the canonical byte-identical transcript. `reference/motivating-example-rounds-1-5.txt`
  is the author's prose reference for Rounds 1–5.
- **Toolchain** — LLVM 14.0.0, Z3 (rev `e417f7d…`), gRPC 1.56.0 (rev
  `6e85620…`), protobuf 23.1; pinned in `repro/614good/Dockerfile`.

### Limitations to record in the verdict

- The analyzer is config-driven but not a general-purpose CLI: the seed
  location (`BlockPlacementPolicyDefault.java:551`) and the input module are
  supplied via `CLODS.conf`; the harness drives only the recorded selections
  and stops at the first unrecorded input.
- Branch/plan IDs derive from iteration over maps keyed by LLVM `Value*`. The
  reference was verified deterministic (byte-identical across independent
  runs) on the pinned toolchain; IDs should not be assumed stable across
  arbitrary LLVM/parser builds.
- `repro/614good/Dockerfile` builds LLVM-adjacent dependencies from source, so
  the first `--build-image` is slow. Ubuntu packages come from live indexes,
  so the recipe is version-identifiable but not bit-for-bit hermetic beyond the
  pinned source revisions and base digest.
- The dynamic half of CLODS (the runtime instrumentation agent and the
  archived `[BM]` logs that select the deviation point each round) is not part
  of this component; the reproduction drives the recorded selections directly
  (`manualOverride: 1`). The IR-generation component (`components/ir-generation`)
  documents how the input bitcode is produced.
- An earlier reference image (`bm_static_analysis:latest`, source `a25fe4ad`,
  retained in the manifest as `legacyCachedImageReference`) matches rounds
  1, 2, 3, 5 and round 4 branch 0 exactly but lists fewer field writers in
  round 4 branches 1/2 than the adopted `222b486b` analyzer; the canonical
  reference is the `222b486b` capture.