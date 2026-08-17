# HBase-4078 — milestone tracker

| Field | Value |
|---|---|
| bug id | HBase-4078 |
| system | HBase |
| jira | https://issues.apache.org/jira/browse/HBASE-4078 |
| source repo | https://github.com/apache/hbase.git |
| fix commit | `df9b82c082571b7dfca4380bffaa38f3fd058927` (trunk, svn@1183071, 2011-10-13) |
| pre-fix commit | `9814ffbaf0eca469bbded025a1dca81271c6d4e6` (0.93-SNAPSHOT) |
| owner | agent-run-4ee9c5a7 |

## Milestones

| ID | Milestone | Status | success | outcome | note |
|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | true | success | folder + trackers created |
| M1 | Identify fix + pre-fix commit | DONE | true | success | `Store.validateStoreFile` added at 2 promotion sites |
| M2 | Build from source at pre-fix | PENDING | null | pending | |
| M3 | Reproduce + merge into production log | PENDING | null | pending | |
| M4 | Anonymize failure path, rebuild, re-reproduce | PENDING | null | pending | |
| M5 | Diagnosis inputs + ground truth | PENDING | null | pending | |
| M6 | LLM diagnosis ×5 | PENDING | null | pending | |
| M7 | Grade runs | PENDING | null | pending | |
| M8 | Summary & finalize | PENDING | null | pending | |

## Log

- 2026-08-17T01:52:58Z agent-run-4ee9c5a7 — claimed HBase-4078; created `evaluations/HBase/HBase-4078/{private,source,logs,diagnosis}`; wrote PROGRESS.md + state.json. First HBase bug in this workspace (`production-logs/HBase/production.log` exists, 3.06 GB, HBase 1.2.7 under YCSB+chaos monkey — so the M3 merge applies).
- 2026-08-17T02:20:00Z agent-run-4ee9c5a7 — M1 DONE. HBASE-4078 "Silent Data Offlining During HDFS Flakiness". Fix commit `df9b82c082` (trunk) = "HBASE-4078 Validate store files after flush/compaction"; saved as `private/fix.diff`. Companion 0.89-fb commit `790feddf2d` saved as `private/fix.0.89.diff` (its message spells out the operator-visible symptom). Pre-fix = `9814ffbaf0`.

  **The fix**: adds `Store.validateStoreFile(Path)` — open the just-written file (`new StoreFile(...).createReader()`), `LOG.error(...) + throw` on `IOException`, `closeReader()` in `finally` — and calls it at exactly **two** production sites, each **before** the file leaves the region `.tmp` dir:
  1. `Store.internalFlushCache` — before `fs.rename(writer.getPath(), dstPath)` promotes the flushed file into the store home dir;
  2. `Store.completeCompaction` — before `StoreFile.rename(...)` promotes the compaction output.

  **Pre-fix (the bug)**, verified in `9814ffbaf0:src/main/java/org/apache/hadoop/hbase/regionserver/Store.java`:
  - `internalFlushCache` 521-533: rename into the live store dir happens first, `sf.createReader()` only afterwards;
  - `completeCompaction` 1221-1232: `if (compactedFile != null)` → `StoreFile.rename(...)` into the store dir first, `result.createReader()` afterwards;
  - `loadStoreFiles` 269-279 (the HBASE-1436 workaround the ticket names): `catch (IOException ioe) { LOG.warn("Failed open of " + p + "; presumption is that file was corrupted at flush and lost edits picked up by commit log replay. Verify!", ioe); continue; }` — so at every later region open the promoted unreadable file is silently skipped.

  Ticket quotes **no** log/stack snippet, so M4's log-literal rewrite is driven by the failure-path literals themselves.
