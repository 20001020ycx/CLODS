# HBase-4078 — result: **0 / 5**

| | |
|---|---|
| **Bug** | HBASE-4078, *"Silent Data Offlining During HDFS Flakiness"* (Blocker, fixed 2011-10-13) |
| **System** | HBase 0.93-SNAPSHOT (pre-fix `9814ffbaf0`), on real HDFS 1.0.4 |
| **Fix** | `df9b82c082` — adds `Store.validateStoreFile()` and calls it at **two** sites, each *before* the new file leaves the region's `.tmp` dir |
| **Symptom given to the LLM** | a store file of `usertable` cannot be read; on every region open the server reports it and carries on without it (WARN + `Invalid HFile version` stack, pasted verbatim) |
| **LLM-facing log** | `logs/symptom.log` — 3.19 GB, 11 945 370 production + 747 348 reproduction records |
| **Subject** | Claude Opus 4.7 (`claude-opus-4-7`), effort `high`, single turn, no follow-ups |
| **Successes** | **0 / 5** under the pre-registered bar; **2 / 5** named root-cause site A with its exact condition |

## Per-run verdicts

| Run | Verdict | Site A (flush promotion) | Site B (compaction promotion) | Condition stated | Endpoint |
|---|---|---|---|---|---|
| 1 | FAIL | miss | miss | no | org gateway |
| 2 | FAIL | miss | miss | no | org gateway |
| 3 | FAIL | miss | miss | no | subscription |
| 4 | FAIL | **hit** | miss | **yes** | subscription |
| 5 | FAIL | **hit** | miss | **yes** | subscription |

Runs 1-2 ran against the org gateway; it then exhausted its daily `claude-opus-4-7` quota, so runs 3-5 ran on the operator's own subscription against `api.anthropic.com`. Model, effort, prompt, staging, tool denials and network lock are identical in both harnesses (`private/run_diagnosis.yscope.sh`, `private/run_diagnosis.subscription.sh`); the served model was verified as `claude-opus-4-7` from the CLI's own `modelUsage` metadata.

## What the ground truth required

The fix inserts one validation call at exactly two places, both *before* the promotion out of `.tmp`:

* **A — flush**: `Store.internalFlushCache` (anon. `FamilyStore.writeSnapshotFile`) renames the flushed file into the live column-family directory at line 526 and only opens it at line 533.
* **B — compaction**: `Store.completeCompaction` (anon. `FamilyStore.installCompactionResult`) renames the compaction output at 1224-1225 inside `if (compactedFile != null)` and only opens it at 1232.

In both, the move is guarded solely by *"did the rename succeed"* / *"was anything written"* — never by *"can the file be opened"*. A PASS required both sites plus that condition.

## Discussion

Every one of the five runs reconstructed the *symptom* path perfectly and identically: `FamilyStore.openStoreFiles`' `catch (IOException) { WARN; continue; }`, `StoreFile.createReader` → `HFile.pickReaderVersion` → `FixedFileTrailer.readFromStream`, down to `HFile.checkFormatVersion`'s `version < 1 || version > 2` firing on `1652127846`. Three of them stopped there and declared the root cause to be "the HFile is corrupt" — run 2 went further and called the silent skip *"not a second bug: it is the intentional policy"*, the exact reading the ticket was filed to overturn. That is the failure mode this bug is built to expose: the model anchors on where the error is **printed** and treats the corrupt bytes as an external fact, never asking who put an unopenable file into the live directory.

Two runs (4 and 5) did ask. Both worked backwards through 3.19 GB of production noise to the flush that created the file, and both stated site A's defect exactly — *"rename-before-verify … the unconditional publish at line 526"*, *"does the flush → validate sequence in the wrong order"*. Run 4 even noticed there was no matching `Registered …` line for that file. This is real, non-trivial reasoning over a realistic log, and it is worth recording that the merged production log did not prevent it. But **no run named site B**: the word *compaction* appears nowhere in any of the five answers, even though the same incident also promoted a truncated compaction output and the log carries its `Merge failed` error. Having explained the one instance in front of them, none generalised to "the same unvalidated promotion exists on the other path that writes store files" — which is precisely what the upstream fix had to do.

So on the pre-registered "name every line the fix changed" bar this is 0/5, and the shape of the misses is the interesting part: 3/5 never leave the symptom site, and the 2/5 that reach the root cause find only the half of it that the log happened to narrate. A deterministic, on-site tool that follows the actual data flow — which file object reached the store directory, and through which call — yields both sites by construction, because both are on the same traced path; the LLM's account, by contrast, is bounded by which instance the log told a story about. That is the gap CLODS is meant to close.

**Standing caveats.** The reproduction injects the filesystem fault at the FS layer (a `DistributedFileSystem` subclass installed via `fs.hdfs.impl`), bounded to the table's own region directory and to two files per regionserver, and the symptom is a logged WARN whose stack names the surfacing frame — the easy half of the answer is handed over by the log, as it would be to a real operator.
