# PROGRESS — bug-1 (EXAMPLE)

> Milestone tracker for the CLODS LLM-diagnosis experiment. This file + `state.json`
> are the source of truth; any agent must resume from here. Keep them in sync.

## Bug metadata
- **Bug ID:** bug-1
- **JIRA (only input):** EXAMPLE-1
- **System:** EXAMPLE
- **Source repo:** https://example.invalid/example.git
- **Fix commit:** `a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2`
- **Pre-fix commit:** `0f1e2d3c4b5a697887796a5b4c3d2e1f0f1e2d3c`
- **Anonymized commit (local `source/` repo):** `f0e1d2c3b4a5968787796a5b4c3d2e1f0f1e2d3c`
- **Symptom (short):** Operation spuriously retried after success, producing duplicate side effects

## Milestone status

| ID  | Milestone | Status | Success | Outcome | Attempts | By | Started (UTC) | Finished (UTC) | Artifacts | Note |
|-----|-----------|--------|---------|---------|----------|----|---------------|----------------|-----------|------|
| M0  | Scaffold & claim | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 09:01:02 | 09:01:03 | `./` | Folder + trackers created. |
| M1  | From JIRA: identify commits | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 09:02:11 | 09:03:40 | `private/fix.diff` | Input = JIRA EXAMPLE-1; pre_fix = fix^. |
| M2  | Checkout pre-fix, build from source, fix deps | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 09:04:00 | 09:21:55 | `reproduce.sh`, `private/deps-fix.patch` | `mvn -pl mod1 -am package -DskipTests`; pinned compiler plugin 3.8.1 (deps-fix.patch). |
| M3  | Reproduce failure | ✅ DONE | true | success | 2 | agent-run-7f3a2c1d | 09:22:10 | 09:28:42 | `logs/symptom.log`, `private/symptom.orig.log`, `reproduce.sh` | Real cluster run failed (env); fell back to unit test `RetryHandlerTest`. |
| M4  | Anonymize source + log, rebuild, commit | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 09:30:00 | 09:52:17 | `source/`, `logs/symptom.log`, `private/anonymization_map.json` | 3 files renamed; 4 log strings → Event A7–A10. Rebuilt from source + re-reproduced. |
| M5  | Prepare inputs & ground truth | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 09:52:30 | 09:55:01 | `symptom.md`, `private/ground_truth.md` | GT = `ClassA1` L88 branch. Leak check: 0 hits. |
| M6  | LLM diagnosis ×5 (network locked) | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 10:00:00 | 10:31:24 | `diagnosis/run_1..5.md` | 5 fresh sessions; web tools off; egress = api.anthropic.com. |
| M7  | Grade each run | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 10:31:30 | 10:38:50 | `diagnosis/run_N.grade.json` | Verdicts: PASS, PASS, FAIL, PASS, FAIL. |
| M8  | Summary & finalize | ✅ DONE | true | success | 1 | agent-run-7f3a2c1d | 10:39:00 | 10:42:13 | `summary.md` | Final: **3/5**. |

## Result
- **Successes:** 3 / 5
- **Per-run:** `[PASS, PASS, FAIL, PASS, FAIL]`
- **Final status:** ✅ COMPLETE

## Log (append-only, UTC)
- 2026-08-10T09:01:03Z — M0 DONE. Scaffolded `evaluations/EXAMPLE/bug-1/` with subdirs.
- 2026-08-10T09:03:40Z — M1 DONE. fix_commit `a1b2c3d…`, pre_fix `0f1e2d…` recorded.
- 2026-08-10T09:21:55Z — M2 DONE. Checked out pre_fix; built `mod1` + deps.
- 2026-08-10T09:28:42Z — M3 DONE (attempt 2). Cluster run blocked by missing env; switched to `RetryHandlerTest` — symptom reproduced in `logs/symptom.log`.
- 2026-08-10T09:52:17Z — M4 DONE. Anonymization: `RetryHandler.java`→`ClassA1.java`, `ReplicaClient.java`→`ClassB2.java`, `MetricsSink.java`→`ClassC3.java`. Log strings rewritten to `Event A7/A8/A9/A10`. Rebuild green; re-run shows anonymized tokens. Committed in fresh local repo `source/`.
- 2026-08-10T09:55:01Z — M5 DONE. `private/ground_truth.md` records the wrong branch: `if (shouldRetry) { … }` evaluated true on a successful response because the guard checked `resp != OK` instead of `resp == RETRYABLE_ERR`. Leak grep: 0 hits on original identifiers.
- 2026-08-10T10:31:24Z — M6 DONE. 5 independent runs via `run_diagnosis.sh`; iptables egress locked to api.anthropic.com:443; `--disallowedTools WebFetch,WebSearch`; single prompt, no follow-ups.
- 2026-08-10T10:38:50Z — M7 DONE. Grading: run_1 PASS (named ClassA1 L88 + the `shouldRetry` guard), run_2 PASS, run_3 FAIL (right file, wrong line, no branch), run_4 PASS, run_5 FAIL (named the symptom location, not the root-cause branch).
- 2026-08-10T10:42:13Z — M8 DONE. Summary written; `state.json.result` set to 3/5.

## Resume instructions for the next agent
All milestones are DONE; this bug is complete. If you are auditing: verify `state.json` matches this file, verify `source/` still compiles, and re-check the grade JSONs against `private/ground_truth.md`. Do not re-run M6 unless you want to reproduce the non-determinism count.