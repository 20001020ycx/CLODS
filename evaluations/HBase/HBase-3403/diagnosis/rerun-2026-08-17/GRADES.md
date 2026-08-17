# Grades — HBase-3403 re-run batch (2026-08-17)

Graded against `RUBRIC.md`, which was written and saved **before** any run in this batch was
read. The first batch (`diagnosis/run_{1..5}.md`) is untouched and not re-graded.

| Run | Bar A (mechanism) | Bar B (non-misdirection) |
|---|---|---|
| 1 | **PASS** | **PARTIAL** |
| 2 | **PASS** | **PASS** |
| 3 | **PASS** | **PASS** |
| 4 | **VOID** — infrastructure | — |
| 5 | **VOID** — infrastructure | — |

**Valid runs: 3. Bar A: 3/3. Bar B: 2/3 PASS + 1 PARTIAL, 0 FAIL.**

Runs 4 and 5 produced no diagnosis. Both returned, as their entire output:

> `API Error: Request rejected (429) · Daily quota exceeded for model group "claude-opus-4-7".
> The quota resets at 2026-08-18T08:00:00-04:00.`

Preserved as `run_{4,5}.QUOTA-FAILED.txt`. This is the same class of event as the first batch's
run-5 retries (session limit / 401) and is scored as neither pass nor fail — the subject was
never asked the question. **The re-run is therefore 3/5 complete, not 5/5.**

## Grounding check (did the runs actually use the production log?)

Every distinctive log line quoted by runs 1-3 was verified verbatim in the 2.9 GB
`logs/symptom.log`, including exact timestamps and encoded region names:

| Claim | Verified |
|---|---|
| `Re-hosting 1 region(s) last served by …43789… (0 already mid-transition, left alone)` | line 10474876, `19:10:00,909` ✓ |
| `Took split parent …598e5e2f… out of service in the catalog` | line 10008965, `19:09:45,475` ✓ |
| `Recorded split child …fa1b663732…` / `…ac6a4798…` | lines 10084300 / 10087547 ✓ |
| run 2's **negative** claim: no `Repairing; unrecorded split child` anywhere | `grep -c` = **0** ✓ |

The negative check is the strongest evidence: run 2 asserted the safety net left no trace in
12 M lines, and that is true. No fabricated quotes were found in any of the three runs.

---

## Run 1 — Bar A PASS, Bar B PARTIAL

**A1** `:26` "**`CatalogWriter.offlineSplitParent` clears `info:server` on the parent row**".
**A2** `:22` "Only **one** of the two daughters (`fa1b663732`) was re-hosted; `ac6a4798` was
silently dropped and never reassigned." **A3** `:66` "Because of step (2) the parent is not in
`hris`, so `processLostRegion` is never invoked with `isOffline() && isSplit()`, and
`recoverSplitChildren` is never called."

Bar B is PARTIAL, not PASS, for two reasons:

1. **Framing.** The headline `:1` is "`LostServerHandler` has no safety net for split daughters",
   and the closing sentence `:94` ends on "Any daughter that the scan misses between the split
   and the RS abort is silently orphaned." The blanking write *is* correctly named as the origin
   in that same sentence — "a precondition that `CatalogWriter.offlineSplitParent` deliberately
   makes impossible by writing `EMPTY_BYTE_ARRAY`" — so the reader can get there. But the primary
   weight is on the recovery gap.
2. **A speculative sub-theory that is wrong.** `:68` invents a scan-visibility race to explain the
   daughter's absence — "for whatever reason (unflushed put not yet visible to the scanner, row
   briefly missing/empty from a memstore rollover on the META RS …)". Nothing in the log supports
   this. Building on it, `:82` concludes the fallback "**wouldn't** repair" the daughter — which
   is **incorrect**: the daughter's META row is genuinely absent, so `recoverSplitChild`'s
   `pair == null` branch would have fired and repaired it. An engineer acting on this could go
   hunting a META memstore visibility bug that does not exist.

Not FAIL: the write-up still contains the correct line and the correct causal statement.

## Run 2 — Bar A PASS, Bar B PASS

**A1** `:7` "`CatalogWriter.offlineSplitParent` … intentionally blanks the parent's server
columns". **A2** `:77` "`inMeta = false` … the safety net that would have re-issued
`addSplitChild` after RS 43789 aborted never ran". **A3** `:62` "Because the parent never enters
`processLostRegion`, this branch never fires."

Bar B PASS. The summary `:97` begins the chain *at the fix site* and derives the rest:
"`offlineSplitParent` writes zero-length `SERVER`/`STARTCODE` bytes on the parent
(`CatalogWriter.java:80-83`); … `getRegionsOfServer` filters it out (`CatalogScanner.java:578`);
… the `hri.isOffline() && hri.isSplit()` branch … never runs".

This run is the most accurate of the three. It gets right the exact point run 1 got wrong —
`:55` marks `if (pair == null || pair.getFirst() == null)` as "**would fire for ac6a**", i.e. the
fallback *would* have repaired the daughter had it been reachable. That is the correct reading and
is what makes the blanking write, rather than the fixup logic, the thing to change.

## Run 3 — Bar A PASS, Bar B PASS

**A1** `:7` "overwrites the parent's `info:server` and `info:serverstartcode` cells with
`HConstants.EMPTY_BYTE_ARRAY`". **A2** `:38` "`inMeta` … → **false** (daughter A never
re-appeared in `.META.`)". **A3** `:3` "When RS … was aborted … daughter A (`ac6a4798…`) was
silently dropped by the master, and there is no code path that ever fixes it up."

Bar B PASS, on the clearest statement of the contradiction in the batch — `:33`: "The step-1
branch (`offlineSplitParent` writes empty SERVER) and the step-4 branch (`getRegionsOfServer`
discards empty SERVER) directly contradict step 5 … **The healing code is dead in the very
scenario it was written for.**"

Minor deduction considered and rejected: `:53` also foregrounds the daughters' "best-effort RPCs"
as a co-factor. That is a fair reading of the split protocol and does not point the reader away
from `CatalogWriter.java:80-83`, which the same sentence cites.

---

## Note on what Bar B can and cannot conclude

The prompt (unchanged from batch 1) asks for **root cause + lines + branches**. It does not ask
for a patch, and none of the three runs proposes one. Bar B is therefore judged on *where the
write-up sends an engineer*, not on a diff. This measures fault localization; it is not evidence
about repair quality, and should not be reported as such.

One asymmetry worth recording for the paper: the real fix touches 6 files, and its largest hunk
is a ~95-line rewrite of `ServerShutdownHandler` (`isDaughterMissing` + `FindDaughterVisitor`).
So a run that discusses the recovery path is **not** off-target — upstream changed it too. What
separates PASS from FAIL is whether the run identifies that the 4-line blanking write is what
makes that recovery path *unreachable*. An engineer who patches only the recovery path ships a
correct-but-still-dead code path and does not fix the bug. All three valid runs cleared that line.
