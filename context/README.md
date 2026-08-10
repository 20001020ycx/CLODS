# CLODS — LLM Diagnosis Evaluation

Companion experiment for paper #1972, *"On-site, Non-speculative Failure Diagnosis
with CLODS."*

This repo holds the methodology and harness for evaluating whether a state-of-the-art
LLM can statically isolate the root cause and failure path of a bug from symptom logs
and source code alone (no internet, no knowledge of the known fix).

---

## How to run one bug (operator quick-start)

You — the operator — run a **Claude Code session on your host** and hand it one filled-in
kickoff prompt. The agent then works autonomously: it clones the buggy source, builds from
source inside a disposable container, reproduces the failure, anonymizes the failure path,
runs 5 network-locked diagnoses, grades them, and writes a summary — committing and
pushing to this repo after every milestone so the run is resumable.

Per-bug toolchains (JDK/Maven/Gradle/gcc versions, etc.) live in containers, so nothing
one bug installs can break another. The agent itself stays on your host, where your git
credentials and API key already work.

### 0. One-time setup (host)

```bash
# clone (or use your existing checkout)
git clone https://github.com/20001020ycx/CLODS.git
cd CLODS

# build the base image once
docker build -t clods-eval -f Dockerfile .
```

Make sure, in the shell you launch Claude Code from:

- **Docker** is installed (`docker --version`).
- **`claude`** is on your PATH (`claude --version`).
- **`ANTHROPIC_API_KEY`** is exported — the agent passes it into the diagnosis container.
- **Git push works** — this repo's remote is over SSH, so your host SSH key must be able
  to push to `github.com:20001020ycx/CLODS.git`. Verify with `ssh -T git@github.com`.

### 1. Start Claude Code (host, repo root)

```bash
cd /path/to/CLODS      # the repo root (contains Dockerfile, context/, evaluations/)
claude                 # open a fresh Claude Code session here
```

### 2. Fill in `context/prompt.md` and paste it as your first message

Open `context/prompt.md` and replace the three placeholders with the bug you want to
evaluate:

| Placeholder | Meaning | Example |
|---|---|---|
| `<JIRA>` | the JIRA ticket (the **only** input) | `HDFS-11896` |
| `<SYSTEM>` | the system category (folder under `evaluations/`) | `HDFS` |
| `<BUGID>` | the bug id (folder name) | `HDFS-11896` |

Then paste the whole file as your single kickoff message. That's the only prompt you send
— the agent drives itself to M8 from there (no follow-ups).

### 3. Watch it run

The agent creates `evaluations/<SYSTEM>/<BUGID>/` and runs milestones M0→M8. To follow
progress in another terminal:

```bash
# live milestone tracker + per-step success/outcome
cat evaluations/<SYSTEM>/<BUGID>/PROGRESS.md
jq '[.milestones[] | {id, outcome, success}]' evaluations/<SYSTEM>/<BUGID>/state.json

# shared, append-only log of all agents
tail -f evaluations/COORDINATION.log

# per-milestone commits (the agent pushes each one)
git log --oneline -- evaluations/<SYSTEM>/<BUGID>
```

### 4. Review the result

When the agent finishes, read:

- `evaluations/<SYSTEM>/<BUGID>/summary.md` — final `successes/5` and discussion.
- `evaluations/<SYSTEM>/<BUGID>/PROGRESS.md` — the milestone tracker.
- `evaluations/<SYSTEM>/<BUGID>/diagnosis/run_1..5.md` + `run_N.grade.json` — the 5
  single-turn diagnoses and their grades vs `private/ground_truth.md`.

A published, illustrative example of a completed folder lives at
`evaluations/EXAMPLE/bug-1/` (a fictional bug, result **3/5**).

---

## Running several bugs in parallel

Open **one Claude Code session per bug**, each with its own filled-in `prompt.md`. They
share this workspace safely because every agent:

- writes **only** to its own folder `evaluations/<SYSTEM>/<BUGID>/`,
- uses a per-bug scratch clone `repos/<SYSTEM>-<BUGID>` (disjoint by bug id),
- appends (never overwrites) to the shared `evaluations/COORDINATION.log` under `flock`,
- commits **only** its own folder (`git add evaluations/<SYSTEM>/<BUGID>`, never
  `git add -A`) and `git pull --rebase`s before every push.

See `context/METHODOLOGY.md` §13 for the full workspace-division and git-discipline rules.

## If an agent dies mid-run

Just start a new Claude Code session in the repo root and paste the **same** filled-in
`prompt.md`. The agent reads `PROGRESS.md` / `state.json`, finds the highest `DONE`
milestone, and resumes from there. Heavy, reproducible artifacts (`source/`, `logs/`,
`repos/`) are gitignored and are deterministically reconstructed on resume from
`anonymization_map.json` + `deps-fix.patch` + `pre_fix_commit` (§9).

---

## What the agent does under the hood (containers)

The agent runs on your host; it only drops into `clods-eval` containers for the steps
that need the per-bug toolchain or network isolation:

```bash
# build & reproduce (M2–M4): network on, repo mounted at /work
docker run --rm -v "$PWD:/work" clods-eval bash -lc \
  'cd /work/repos/<SYSTEM>-<BUGID> && <build cmd> && bash /work/evaluations/<SYSTEM>/<BUGID>/reproduce.sh'

# diagnose (M6): network locked to api.anthropic.com only, 5× single prompt
docker run --rm --cap-add=NET_ADMIN \
  -v "$PWD/evaluations/<SYSTEM>/<BUGID>:/bug:ro" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --entrypoint /opt/clods/run_diagnosis.sh \
  clods-eval /bug
```

Git commits and pushes (after every milestone) happen on the host — no container needed,
which is exactly why the agent runs on the host rather than inside one. Full Docker
details in `context/METHODOLOGY.md` §11.

---

## Contents

| Path | What |
|---|---|
| `context/METHODOLOGY.md` | The agent runbook — the single source of truth each evaluation agent reads and follows. |
| `context/prompt.md` | The kickoff prompt an operator hands to an agent for one bug (fill in JIRA/system/bugid, then paste). |
| `Dockerfile` | The per-bug container base image (build toolchain + Claude Code CLI). The agent runs on the host and uses this image only for build/reproduce/diagnose steps. |
| `context/run_diagnosis.sh` | Helper that runs the 5× network-locked, single-prompt LLM diagnoses inside the container. |
| `evaluations/` | **Per-bug progress, tracked** (lightweight files: tracker, diagnosis runs, grades, summary). Heavy artifacts (`source/`, `logs/`, `repos/`) are gitignored. `evaluations/EXAMPLE/bug-1/` is a published illustrative example; `evaluations/COORDINATION.log` is the shared append-only log. |

See `context/METHODOLOGY.md` for the full procedure: milestones M0–M8, anonymization
rules, grading rubric, Docker usage, and the resumption protocol.