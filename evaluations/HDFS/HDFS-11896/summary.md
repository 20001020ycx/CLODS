# Summary — HDFS-11896

## Result
**Successes: 0 / 5**

| Run | Verdict | Why |
|-----|---------|-----|
| 1 | FAIL | Missed `resetBlocks()`; wrongly claims death clears no fields. Found only the `register()`-reorder workaround. |
| 2 | FAIL | Missed `resetBlocks()`; claims dfsUsed/blockPoolUsed also stay stale (false). |
| 3 | FAIL | Missed `resetBlocks()`; says capacity/dfsUsed/otherUsed are "not reset" (false). |
| 4 | FAIL | Missed `resetBlocks()`; claims death clears no fields (false). |
| 5 | FAIL | Missed `resetBlocks()`; never explains the why-only-other-used asymmetry. |

## System / bug
- **System:** Apache Hadoop **HDFS**. Real bug: HDFS-11896, "Non-dfsUsed will be doubled on
  dead node re-registration" (branch-2.7 pre-fix `b516235`); only the JIRA id was scrubbed and
  `nonDfsUsed` renamed to `otherUsed`.

## Ground truth
The root cause is **`DatanodeDescriptor.resetBlocks()` zeroes every node-level total except
`otherUsed`** — so a dead node's descriptor keeps a stale `otherUsed`, which is then re-added
to the cluster total when it re-registers. This is the canonical fix (and the only change on
trunk/2.8/2.9). Branch-2.7 additionally reordered `HeartbeatManager.register()` so
`addDatanode` reads the field after it is zeroed; that reorder is a second, sufficient patch,
but it is not the root cause — if `resetBlocks()` reset `otherUsed`, the ordering would not
matter.

## Grading
PASS requires naming the exact root-causing line (`resetBlocks()`'s missing `setOtherUsed(0)`)
and the branch that dictates the failure. **No run named `resetBlocks()`.** All five instead
identified only the `register()` add-before-reset ordering (a working *workaround*, not the
root cause) and, in most cases, **stated the death path incorrectly** — asserting that the
dead node's `capacity`/`dfsUsed`/etc. are also left stale, when `resetBlocks()` in fact zeroes
those and forgets only `otherUsed`. Because they never located `resetBlocks()` and misdescribed
why the value is stale, none isolated the root cause. Partial credit is not a pass → **0/5**.

## Discussion
This run used the tightened M5 symptom (bare observable + log pointer only). The previous run's
`symptom.md` had leaked the narrowing "only other-used is wrong; capacity and DFS-used stay
correct," and with that hint all 5 runs had named `resetBlocks()` (scored 5/5). Removing the
hint dropped it to **0/5**: with no one telling the model which field was singled out, it never
investigated why only other-used diverges, mischaracterized the death path, and settled on a
plausible-but-secondary fix. The collapse from 5/5 to 0/5 on a one-sentence symptom change is
direct evidence that the earlier result was an artifact of leaked narrowing, and that without
grounding the LLM did not isolate the true root cause — the case for a deterministic,
field-level observation tool (CLODS).
