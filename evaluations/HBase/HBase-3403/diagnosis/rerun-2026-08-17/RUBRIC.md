# Grading rubric — HBase-3403 re-run (pre-registered)

**Written 2026-08-17, BEFORE any `run_N.md` of this batch was read.** Pre-registration is
deliberate: the grader (this agent) knows the JIRA and the fix, so fixing the bar in advance is
the only way to keep "did it pass" from drifting into "can I construct a reading where it passed".

Batch: `diagnosis/rerun-2026-08-17/run_{1..5}.md`. The first batch (`diagnosis/run_{1..5}.md`)
is NOT re-graded and NOT modified.

## What the runs were asked

Byte-identical to the first batch (md5 `05702b26ee05030997f3165b714cf85b`):

> Given the source code at <STAGE>/source and the production log at <STAGE>/logs/symptom.log
> (this is a large, realistic production log — grep it for the symptom rather than reading it
> whole), what is the root cause of the failure: <symptom>? Identify the specific lines of code
> and the exact logical conditions (branches) that dictate this failure path.

Note the prompt asks for **root cause + lines + branches**. It does *not* ask for a patch. Bar B
below is therefore graded on where the write-up *points an engineer*, not on whether a diff is
present — penalising a run for not volunteering a patch it was never asked for would be unfair.

## Ground truth (from `private/ground_truth.md` + `private/fix.diff`)

Real fix `0d31ac5f37a2e8866884bb216a3485eea652a822` touches 6 files. The **root cause** is the
4-line deletion in `MetaEditor.offlineParentInMeta` (anon: `CatalogWriter.offlineSplitParent`,
lines 80-83), which stops blanking the split parent's `SERVER_QUALIFIER`/`STARTCODE_QUALIFIER`.

Causal chain:
1. Split commits; parent row is marked offline+split AND its server column is blanked.
2. RS dies. Master enumerates the dead server's regions via
   `MetaReader.getServerUserRegions` (anon: `CatalogScanner.getRegionsOfServer`) — the filter at
   :578 `pair.getSecond() == null || !pair.getSecond().equals(hsi)` → `continue` **skips the
   parent**, because its server column is now empty.
3. So `ServerShutdownHandler.processDeadRegion` (anon: `processLostRegion`) never sees the
   parent, and its `hri.isOffline() && hri.isSplit()` branch at :179 — the one guarding
   `fixupDaughters` (anon: `recoverSplitChildren`) — is **unreachable**.
4. The daughter that never made it into `.META.` is never repaired → orphan → hbck INCONSISTENT.

**The `getServerUserRegions` filter is NOT changed by the fix.** The other hunks
(`isDaughterMissing` + `FindDaughterVisitor`, the `fullScan(startrow)` overload, CatalogJanitor,
HMaster) make `fixupDaughter` *correct* once reached; **none of them makes it reachable.** An
engineer who patches only the recovery path still ships the bug.

## Bar A — mechanism (user's wording)

> "Parent region has already marked as offline, but ONE of the daughter has not been added into
> meta table. This causes daughter regions inconsistent after crash."

PASS requires **all three**, stated (not merely implied):
- **A1** parent is offlined/split-marked in `.META.` at split commit;
- **A2** one daughter is absent from `.META.`;
- **A3** the crash of the region server is what turns A1+A2 into the permanent inconsistency
  (i.e. recovery is what fails, not the split itself).

Wording need not match the user's; code-level equivalents count. Naming the anonymized
identifiers counts (the LLM cannot know the real ones).

## Bar B — non-misdirection

> "make sure the llm's diagnosis suggestion is not deviating the real actual fix, like an
> engineer wouldn't be mis-directed by the suggestion."

Graded as: **an engineer who reads only this write-up and acts on it — where do they edit?**

- **PASS** — the write-up makes the blanking write in `offlineSplitParent` the thing to change,
  or presents it as the origin such that a reader lands there. Also mentioning the filter or the
  recovery path is fine *provided* the blanking write is identified as the cause, since the real
  fix touches those files too.
- **PARTIAL** — the blanking write is present and correct, but the framing (headline, "the bug
  is", recommendation) puts primary weight on the filter or the recovery gap, so a hurried
  reader could plausibly patch the wrong file first. Still on-path; costs time, not correctness.
- **FAIL** — the blanking write is absent, wrong, or explicitly ruled out; or the write-up
  directs the reader primarily at off-path code. An engineer following it would not fix the bug.

Off-path sites named as *context* are not penalised; named as *the place to change* they are.

## Reporting

Per run: A1/A2/A3 verdicts + Bar B verdict, each with a verbatim quote and line cite from that
run. Direct quotes only — no paraphrase standing in for evidence. Failures reported as plainly
as passes. Any run I find ambiguous is called ambiguous rather than resolved in the LLM's favour.
