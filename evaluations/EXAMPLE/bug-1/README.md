# Example: `bug-1` (EXAMPLE) — published for review

This folder is a **published, illustrative example** of the per-bug evaluation format
described in [`../../../context/METHODOLOGY.md`](../../../context/METHODOLOGY.md). It uses a
**fictional** bug (`bug-1`, JIRA `EXAMPLE-1`) whose only purpose is to show what a
completed bug folder looks like — the milestone tracker, anonymization map, ground truth,
diagnosis runs, grades, and summary.

Real per-bug evaluation outputs are gitignored (`evaluations/` is ignored except this
`EXAMPLE/` subtree) and stay local.

Files:
- `PROGRESS.md` / `state.json` — the milestone tracker (source of truth for resume; see §4).
- `symptom.md` — the symptom description given to the diagnosis LLM.
- `source/` — the anonymized, from-source-built source tree given to the LLM (not populated in this example).
- `logs/symptom.log` — the anonymized symptom log given to the LLM.
- `diagnosis/run_1..5.md` + `run_N.grade.json` — the 5 single-turn diagnoses and their grades.
- `private/` — answer key and build artifacts, never given to the LLM:
  `ground_truth.md`, `anonymization_map.json`, `fix.diff`, `deps-fix.patch`.
- `summary.md` — final result (3/5) and discussion.

Result for this example: **3 / 5** diagnoses isolated the exact root-causing line and branch.