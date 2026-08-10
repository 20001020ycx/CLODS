# PROGRESS — HDFS-11896

- **System:** HDFS
- **JIRA:** https://issues.apache.org/jira/browse/HDFS-11896
- **Repo:** https://github.com/apache/hadoop.git
- **Agent:** agent-run-da18f700
- **Scratch clone:** repos/HDFS-HDFS-11896 (gitignored)

## Milestones

| ID | Milestone | Status | success |
|----|-----------|--------|---------|
| M0 | Scaffold & claim | DONE | true |
| M1 | Identify fix + pre-fix commit | DONE | true |
| M2 | Build from source at pre-fix | PENDING | null |
| M3 | Reproduce the failure | PENDING | null |
| M4 | Anonymize + rebuild + re-confirm | PENDING | null |
| M5 | Prepare diagnosis inputs & ground truth | PENDING | null |
| M6 | Run LLM diagnosis ×5 (network locked) | PENDING | null |
| M7 | Grade each run | PENDING | null |
| M8 | Summary & finalize | PENDING | null |

## Log
- 2026-08-10 M0 DONE: created bug folder, subdirs (private/source/logs/diagnosis), PROGRESS.md, state.json. Claimed bug. Base docker image `clods-eval` build kicked off.
- 2026-08-10 M1 DONE: JIRA HDFS-11896 = "Non-dfsUsed doubled on dead node re-registration". Fix commit `c4a85c694fae3f814ab4e7f3c172da1df0e0e353` (trunk), pre-fix `11ece0bda1f6e5dd9d0f828b7c29acacf6087baa`. Functional change is entirely in `DatanodeDescriptor.resetBlocks()` (+ making a DataNode test helper public, + a new test). Saved private/fix.diff. Base image `clods-eval` built OK.

