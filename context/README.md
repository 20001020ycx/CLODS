# CLODS — LLM Diagnosis Evaluation

Companion experiment for paper #1972, *"On-site, Non-speculative Failure Diagnosis
with CLODS."*

This repo holds the methodology and harness for evaluating whether a state-of-the-art
LLM can statically isolate the root cause and failure path of a bug from symptom logs
and source code alone (no internet, no knowledge of the known fix).

## Contents

| Path | What |
|---|---|
| `context/METHODOLOGY.md` | The agent runbook — the single source of truth each evaluation agent reads and follows. |
| `Dockerfile` | The containerized environment (build toolchain + Claude Code CLI). Agents run inside it, never on bare metal. |
| `context/run_diagnosis.sh` | Helper that runs the 5× network-locked, single-prompt LLM diagnoses. |
| `evaluations/` | **Per-bug outputs (gitignored).** Each `<SYSTEM>/<BUGID>/` folder holds the milestone tracker, anonymized source, logs, and diagnosis results. |

## Quick start

```bash
# build the image
docker build -t clods-eval -f Dockerfile .

# setup phase (M0-M5): network on
docker run --rm -it -v "$PWD:/work" -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" clods-eval

# diagnosis phase (M6): network locked to api.anthropic.com
docker run --rm --cap-add=NET_ADMIN \
  -v "$PWD/evaluations/<SYSTEM>/<BUGID>:/bug:ro" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --entrypoint /opt/clods/run_diagnosis.sh \
  clods-eval /bug
```

See `context/METHODOLOGY.md` for the full procedure, milestones, anonymization rules,
grading rubric, and resumption protocol.