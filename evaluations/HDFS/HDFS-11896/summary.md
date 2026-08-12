# Summary — HDFS-11896

## Result (two readings — see discussion)
- **Isolated a correct, sufficient root-cause branch + mechanism: 5 / 5.**
- **Identified the *canonical* root cause (`resetBlocks()` omitting `setOtherUsed(0)`): 0 / 5.**

| Run | Verdict | Strict (resetBlocks) | What it named |
|-----|---------|----------------------|----------------|
| 1 | PASS | FAIL | `register()` reorder + mechanism; wrongly says death clears no fields. |
| 2 | PASS | FAIL | `register()` reorder + arithmetic table; misses `resetBlocks`. |
| 3 | PASS | FAIL | `register()` reorder; mentions `removeBlocksAssociatedTo` but not the `resetBlocks` asymmetry. |
| 4 | PASS | FAIL | `register()` reorder, log-cited; wrongly says death clears no fields. |
| 5 | PASS | FAIL | `register()` reorder; most careful death-path wording; still no `resetBlocks`. |

## System / bug
- **System:** Apache Hadoop **HDFS** (identifiers kept). Real bug: HDFS-11896,
  "Non-dfsUsed will be doubled on dead node re-registration" (branch-2.7 pre-fix `b516235`);
  only the JIRA id was scrubbed and `nonDfsUsed` renamed to `otherUsed`.

## What changed in this run (why it matters)
This run used the **tightened M5 symptom**: `symptom.md` states only the bare observable
(`getOtherUsedSpace` reads ~3 MB, should read ~2 MB) plus a pointer to the log. The previous
run's `symptom.md` had also narrated the trigger ("a node dies and re-registers") and, crucially,
the narrowing "only other-used is wrong; capacity and DFS-used stay correct." Those were
cause-leaks and were removed.

The effect is striking and is the headline finding:

- **With the narrowing hint (previous run): 5/5 named `DatanodeDescriptor.resetBlocks()`'s
  missing `setOtherUsed(0)` — the canonical root cause.**
- **Without it (this run): 0/5 named `resetBlocks()`.** All five instead traced only the
  *other* half of the branch-2.7 fix — the `HeartbeatManager.register()` add-before-reset
  ordering — and **mischaracterized the death path**, most of them explicitly (and wrongly)
  asserting that the dead node's `capacity`/`dfsUsed`/etc. are *also* left stale. In reality
  `resetBlocks()` zeroes those and only forgets `otherUsed`; that asymmetry is *why only
  other-used leaks*, and none of the runs discovered it. The "only other-used is wrong"
  sentence in the old symptom had been doing that work for them.

## Ground truth
The branch-2.7 fix changed two coupled locations; **fixing either resolves it**:
1. `DatanodeDescriptor.resetBlocks()` zeroes every node total **except** `otherUsed` — the
   canonical root cause (and the *only* change on trunk/2.8/2.9).
2. `HeartbeatManager.register()` calls `addDatanode(d)` (→ `stats.add` reads the stale
   `otherUsed`) **before** `updateHeartbeatState(EMPTY_ARRAY)` resets it.

## Discussion
Read charitably, the LLM did well: on an *either/or* fix, all five runs isolated a genuine
root-causing branch that the fix diff changed (`register()` L189-196, the `if(!d.isAlive)`
branch), gave the exact leak mechanism (stale `otherUsed` re-added by `addDatanode`, never
compensated, so the running total stays high), matched the 2→1→2→3 MB arithmetic to the log,
and proposed a working fix (reorder `register`). By the bar "isolate *a* correct root-causing
line + branch that leads to a valid fix," that is 5/5.

Read strictly, it did **not** find the bug's canonical root cause. The upstream fix's primary
change — the one present on every branch — is the missing `setOtherUsed(0)` in `resetBlocks()`.
No run named it; worse, most built an incorrect model of the death path (that nothing is
cleared), which would predict capacity/DFS-used doubling too — a contradiction they never
tested because the tightened symptom no longer told them "only other-used is wrong." That the
canonical-site hit-rate collapsed from **5/5 to 0/5** the moment the narrowing sentence was
removed is direct evidence that (a) leaked narrowing in a symptom can manufacture an
apparently-strong result, and (b) absent that scaffolding the LLM anchored on a
locally-plausible but incomplete cause. This is a clean argument for CLODS-style grounding:
a deterministic tool that actually observes which field diverges would have pointed straight
at the `resetBlocks()` asymmetry the LLM missed.

**Recommended headline for aggregation:** report the strict reading (**0/5 on the canonical
root cause**) as the primary number for this bug, with the note that all five did find the
sufficient `register()`-reorder fix. The per-run `*.grade.json` carry both verdicts
(`verdict` = PASS on "a valid root-cause branch", `verdict_strict_resetBlocks_required` = FAIL).
