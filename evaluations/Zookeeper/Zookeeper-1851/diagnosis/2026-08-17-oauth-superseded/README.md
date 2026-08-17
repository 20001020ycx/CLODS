# Superseded batch — 2026-08-17, OAuth via api.anthropic.com

Run before `context/run_diagnosis.sh` was switched to the
**yscope-anthropic-paper-validation** gateway. Same inputs (anonymized `source/` + the
1.5 GB merged production log + the bare-observable `symptom.md`) and the same model pin
(`claude-opus-4-7`, effort high), but reached over the old path: copied OAuth credentials
against `api.anthropic.com`, egress locked to that host.

- `run_1..4.md` completed; `run_5.md` never produced an answer — the subscription account
  hit its session limit ("resets 5:30pm UTC"), which is precisely the failure mode the
  gateway's long-lived bearer token exists to avoid.
- Kept for reference only. The authoritative 2026-08-17 batch is `../2026-08-17/`,
  run through the gateway.
