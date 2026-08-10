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
| `context/prompt.md` | The kickoff prompt an operator hands to an agent for one bug (fill in JIRA/system/bugid). |
| `Dockerfile` | The containerized environment (build toolchain + Claude Code CLI). Agents run inside it, never on bare metal. |
| `context/run_diagnosis.sh` | Helper that runs the 5× network-locked, single-prompt LLM diagnoses. |
| `evaluations/` | **Per-bug progress, tracked** (lightweight files: tracker, diagnosis runs, grades, summary). Heavy artifacts (`source/`, `logs/`, `repos/`) are gitignored. `evaluations/EXAMPLE/bug-1/` is a published illustrative example; `evaluations/COORDINATION.log` is the shared append-only log. |

## Running a bug

Multiple agents can work in this workspace at once — each owns one
`evaluations/<SYSTEM>/<BUGID>/` folder, commits only there, and pushes after every
milestone. See `context/METHODOLOGY.md` §13 for workspace division and git discipline.

```bash
# build the base image
docker build -t clods-eval -f Dockerfile .

# setup phase (M0-M5): network on; inside, follow context/prompt.md for one bug
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