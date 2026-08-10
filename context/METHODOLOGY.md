# LLM Diagnosis Evaluation — Agent Runbook

> **Audience:** This document is the single source of truth for any Claude Code agent
> that reproduces and evaluates one bug for the CLODS paper's LLM-diagnosis experiment
> (paper #1972, "On-site, Non-speculative Failure Diagnosis with CLODS").
> Read it **in full** before touching anything. Each agent owns exactly one bug and
> must be able to resume another agent's partially completed bug without information loss.

---

## 0. What you are doing (the big picture)

You are testing whether a state-of-the-art LLM, given only **symptom logs + source code**
(and **no** internet, **no** knowledge of the known fix), can statically isolate the
**exact root-causing line(s) and the exact branch conditions** that dictate a failure path.

For your assigned bug you will, in order:

1. Find the commit *just before* the bug fix was applied.
2. Compile the system at that commit.
3. Reproduce the failure (real-system run, or a unit test if a full run is impractical).
4. **Anonymize** the source: rename files and rewrite the log/print statements on the
   failure path, so the LLM cannot map symptoms to known fixes from memory. Commit it.
5. Run the LLM diagnosis **5 times**, independently, with internet blocked and a
   single fixed prompt. No follow-up prompts.
6. Grade each of the 5 runs against ground truth (did it name the exact lines + branches?).
7. Record everything in a milestone-tracker file so any agent can resume your work.

You do NOT need internet during diagnosis. You DO need it for clone/build/reproduce.
You run **inside a Docker container**, never on bare metal (see §11).

---

## 1. Glossary

| Term | Meaning |
|---|---|
| **bug** | One failure in one system, identified by a bug id (e.g. `HDFS-11896`). |
| **fix commit** | The upstream commit that fixed the bug. |
| **pre-fix commit** | The parent of the fix commit (the last commit where the bug exists). This is what you check out. |
| **failure path** | The chain of code locations from the logged symptom down to the root cause (the call stack visible in the symptom log + the lines the fix changed). |
| **symptom** | The externally visible failure (error message / exception / wrong behavior) the user sees. |
| **symptom log** | The log file produced when the bug is triggered, containing the anonymized log statements. |
| **anonymization** | Renaming files and rewriting log/print string literals on the failure path. |
| **ground truth** | The exact line(s) and branch condition(s) the real fix touched. Derived from the fix-commit diff. Used only for grading, **never** shown to the diagnosis LLM. |
| **run** | One independent LLM diagnosis attempt. 5 runs per bug. |

---

## 2. Directory layout & paths

All work lives under `/mnt/SSD-4T/ycx/CLODS/`. The layout is:

```
CLODS/
├── context/
│   ├── METHODOLOGY.md            # this file
│   ├── Dockerfile
│   └── run_diagnosis.sh          # helper for the 5x network-locked diagnosis
└── evaluations/
    └── <SYSTEM>/                 # e.g. HDFS, Presto, Blink, Velox
        └── <BUGID>/              # e.g. HDFS-11896, or the dry-run "bug-1"
            ├── PROGRESS.md       # ★ milestone tracker (the source of truth for resume)
            ├── state.json        # ★ machine-readable mirror of PROGRESS milestones
            ├── reproduce.sh      # system-specific script that reproduces the bug (you write it)
            ├── private/          # NEVER given to the diagnosis LLM
            │   ├── ground_truth.md       # exact lines+branches the fix changed
            │   ├── anonymization_map.json # original→anonymized file/string mapping
            │   └── fix.diff                 # the raw fix-commit diff
            ├── source/           # the anonymized, compilable source tree given to the LLM
            ├── logs/
            │   └── symptom.log   # the anonymized symptom log given to the LLM
            ├── symptom.md        # the symptom description given to the LLM
            ├── diagnosis/
            │   ├── run_1.md ... run_5.md   # full raw output of each of the 5 runs
            │   └── run_1.grade.json ...   # per-run grading verdict
            └── summary.md         # final: successes/5 + discussion
```

**Path rule:** the `<SYSTEM>/<BUGID>` folder is created under `evaluations/`. For the
dry run we use `evaluations/EXAMPLE/bug-1/`.

---

## 3. Milestones (the heart of resumability)

Work is split into ordered milestones **M0–M8**. Each milestone is atomic: it is either
`PENDING`, `IN_PROGRESS`, `DONE`, `BLOCKED`, or `FAILED`. **Rules:**

1. On startup, read `PROGRESS.md` + `state.json`. Find the highest-numbered `DONE`
   milestone. Resume at the next one. Never redo a `DONE` milestone (see exception in §10).
2. Before starting a milestone, set it to `IN_PROGRESS` and **atomically** rewrite
   `state.json` (write to a temp file in the same dir, then `mv` over the old one) so a
   kill mid-write cannot corrupt the tracker.
3. When a milestone finishes, set it to `DONE`, record artifacts (paths) and a one-line
   note. Append a timestamped line to the `## Log` section of `PROGRESS.md`.
4. Only **one** milestone may be `IN_PROGRESS` at a time.
5. If a milestone genuinely cannot complete (e.g. bug won't reproduce), set it to
   `BLOCKED` with a precise reason, and stop. Do not silently skip ahead.

| ID | Milestone | Network | Key outputs |
|---|---|---|---|
| M0 | Scaffold & claim the bug folder | — | folder, `PROGRESS.md`, `state.json` |
| M1 | Identify fix commit + pre-fix commit | on | `fix.diff`, bug metadata in `state.json` |
| M2 | Check out pre-fix commit & compile | on | built source tree |
| M3 | Reproduce the failure | on | `logs/symptom.log` (pre-anonymization), `reproduce.sh` |
| M4 | Anonymize source + log statements, rebuild, re-confirm reproduction, commit | off | `source/`, `logs/symptom.log` (anonymized), `private/anonymization_map.json`, anon commit hash |
| M5 | Prepare diagnosis inputs & ground truth | off | `symptom.md`, `private/ground_truth.md` |
| M6 | Run LLM diagnosis ×5, network locked, single prompt | API-only | `diagnosis/run_1..5.md` |
| M7 | Grade each run vs ground truth | off | `diagnosis/run_N.grade.json` |
| M8 | Write summary & finalize | off | `summary.md`, final `PROGRESS.md` |

---

## 4. The milestone tracker format (`PROGRESS.md` + `state.json`)

`state.json` is a machine-parsed mirror so any agent can resume. `PROGRESS.md` is the
human-readable version with the same fields plus a running log. **Keep them in sync.**

`state.json` schema:

```json
{
  "bug_id": "HDFS-11896",
  "system": "HDFS",
  "source_repo": "https://github.com/apache/hadoop.git",
  "fix_commit": "<sha>",
  "pre_fix_commit": "<sha>",
  "anonymized_commit": "<sha in a fresh local repo>",
  "symptom_short": "<one-line symptom>",
  "milestones": [
    {"id": "M0", "status": "DONE",     "started": "...", "finished": "...", "attempts": 1, "by": "agent-run-<id>", "artifacts": ["..."], "note": "..."},
    {"id": "M1", "status": "DONE",     "...": "..."},
    {"id": "M2", "status": "IN_PROGRESS","...": "..."},
    {"id": "M3", "status": "PENDING",  "...": "..."},
    {"id": "M4", "status": "PENDING",  "...": "..."},
    {"id": "M5", "status": "PENDING",  "...": "..."},
    {"id": "M6", "status": "PENDING",  "...": "..."},
    {"id": "M7", "status": "PENDING",  "...": "..."},
    {"id": "M8", "status": "PENDING",  "...": "..."}
  ],
  "result": null
}
```

`result` is filled at M8: `{"successes": 3, "total": 5, "per_run": ["PASS","FAIL",...]}`.

Write timestamps as ISO-8601 strings. In the container, get time with `date -u +%FT%TZ`
(the workflow scheduler forbids `Date.now()` in *workflow scripts* only; shell `date` is fine).

Atomic write pattern (use it for every `state.json` update):

```bash
python3 - <<'PY'
import json, os, tempfile
p = "/path/to/state.json"
d = json.load(open(p))
# ...mutate d...
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), suffix=".tmp")
with os.fdopen(fd,"w") as f: json.dump(d, f, indent=2); f.write("\n")
os.replace(tmp, p)
PY
```

---

## 5. Step-by-step procedure

> Concrete commands assume you are inside the container (§11). Adjust paths to your
> `<BUG_DIR>` = `/mnt/SSD-4T/ycx/CLODS/evaluations/<SYSTEM>/<BUGID>`.

### M0 — Scaffold & claim
1. Create `<BUG_DIR>` and the subdirs (`private`, `source`, `logs`, `diagnosis`).
2. Write `PROGRESS.md` and `state.json` with all milestones `PENDING` except M0.
3. Set `agent-run-<id>` = first 8 chars of `git rev-parse HEAD` of this repo, or
   `uuidgen | cut -c1-8` if no repo. Put it in every milestone's `by` field you touch.
4. Mark M0 `DONE`.

### M1 — Identify commits
1. In a **scratch clone** of the system repo (under `/work/repos/<SYSTEM>`), locate the
   fix for the bug id (JIRA/GitHub). The fix commit is the one whose diff resolves the bug.
2. `pre_fix_commit = git rev-parse <fix_commit>^`.
3. Save `git show <fix_commit> > <BUG_DIR>/private/fix.diff`.
4. Record `fix_commit` and `pre_fix_commit` in `state.json`. Mark M1 `DONE`.

### M2 — Check out pre-fix & compile
1. In the scratch repo: `git checkout <pre_fix_commit>`.
2. Build using the system's build (`mvn -pl <module> -am package -DskipTests`,
   `./gradlew build -x test`, etc.). Record the exact build command in `PROGRESS.md`.
3. If the build is intractably large, build **only the module(s) on the failure path**
   plus their dependencies. Note what you built.
4. Capture the build command in `reproduce.sh` (top of file) so M3/M4 can reuse it.
5. Mark M2 `DONE` with the built artifact paths.

### M3 — Reproduce the failure
1. Write `reproduce.sh`: a self-contained script that (a) builds if needed, (b) runs
   the real system or a targeted unit test, and (c) writes the failure log to
   `<BUG_DIR>/logs/symptom.log`. Prefer the real failing operation; fall back to a unit
   test only if a full cluster run is impractical, and say so in the note.
2. Run it. Confirm the symptom appears in `logs/symptom.log`.
3. Keep a copy of the **pre-anonymization** log in `private/symptom.orig.log` (needed to
   verify anonymization later).
4. Mark M3 `DONE`. If the bug does not reproduce after genuine effort, set M3 `BLOCKED`
   with the exact commands tried and outputs, then stop.

### M4 — Anonymize (the critical step)
Goal: prevent the LLM from matching symptoms to known fixes via parametric memory, while
keeping the source compilable and the log still traceable. See §6 for the full procedure.

1. Rename files on the failure path to neutral names; rewrite log/print string literals
   on the failure path to neutral-but-unique tokens. Record everything in
   `private/anonymization_map.json`.
2. Rebuild. Re-run `reproduce.sh`. Confirm the failure still reproduces and
   `logs/symptom.log` now contains the **anonymized** log strings.
3. Commit the anonymized tree in a **fresh local git repo** at `<BUG_DIR>/source`
   (`git init`, add all, commit). This gives a stable `anonymized_commit` and a clean
   diff for auditing. Record the hash in `state.json`.
4. Mark M4 `DONE`.

### M5 — Prepare diagnosis inputs & ground truth
1. Write `symptom.md`: a 2–6 line plain-English description of the symptom **only**.
   Do **not** mention the fix, the bug id, the system name beyond what's unavoidable, or
   any root-cause hint. (Anonymizing the system name is optional but preferred.)
2. Derive `private/ground_truth.md` from `private/fix.diff`: list the **exact file:line(s)**
   the fix changed and the **exact branch/condition** that was wrong (before the fix).
   This is the answer key. It lives only in `private/`.
3. Verify `source/` and `logs/symptom.log` are the anonymized versions and contain no
   original identifiers that appear in the fix diff (grep the fix diff's distinctive
   tokens against the anonymized tree; expect zero hits).
4. Mark M5 `DONE`.

### M6 — Run LLM diagnosis ×5 (network locked, single prompt, no follow-ups)
1. Use `context/run_diagnosis.sh` (§7). It runs the diagnosis **5 times**, each in a
   fresh, stateless session, with web tools disabled and egress restricted to the
   Anthropic API only. It writes `diagnosis/run_N.md` (full transcript+answer).
2. The **exact prompt** (substitute the container paths):

   ```
   Given the source code at /bug/source and the symptom logs located at /bug/logs/symptom.log,
   what is the root cause of the failure: <SYMPTOM from symptom.md>?
   Identify the specific lines of code and the exact logical conditions (branches) that
   dictate this failure path.

   IMPORTANT: Do NOT connect to the internet or find other bugs with a similar symptom.
   Instead rely purely on your reasoning to diagnose this failure.
   ```

   `<SYMPTOM>` = the full text of `symptom.md`. The paths point at the anonymized tree.
3. **No follow-up prompts.** Whatever the model returns in that single turn is the run's
   answer. Do not iterate, clarify, or hint.
4. Mark M6 `DONE`.

### M7 — Grade each run
1. For each `run_N.md`, decide PASS/FAIL by comparing its claimed root-causing lines and
   branches to `private/ground_truth.md`:
   - **PASS** = names the exact root-causing line(s) **and** the exact branch condition(s)
     that dictate the failure path (semantic match to ground truth; line numbers may
     differ after anonymization, so match by code identity, not line number).
   - **FAIL** = anything else (wrong line, right line but wrong/missing branch, partial,
     or no concrete answer).
2. Write `diagnosis/run_N.grade.json`: `{"verdict":"PASS"|"FAIL","justification":"...",
   "claimed_lines":[...],"claimed_branches":[...],"gt_lines":[...],"gt_branches":[...]}`.
3. Mark M7 `DONE`.

### M8 — Summary & finalize
1. Compute `successes = count(PASS)` out of 5. Write `summary.md`:
   - the bug id, system, symptom,
   - successes/5,
   - per-run verdict table,
   - a 3–6 sentence discussion: did the LLM isolate the root cause *deterministically*
     (all/most runs PASS) or not? Tie back to whether LLMs can bypass deterministic tools
     or need something like CLODS to ground reasoning.
2. Set `state.json.result` and mark M8 `DONE`.

---

## 6. Anonymization procedure (detail)

Inputs: the failure path (files named in the fix diff + files in the symptom-log stack
trace) and the build system. Outputs: a compilable `source/` tree + updated `symptom.log`.

**File renaming.**
- For each file on the failure path, rename to a neutral scheme preserving directory
  *depth* but not names: e.g. `hadoop-hdfs/.../BlockManager.java` → `mod1/.../ClassA1.java`.
  Use a stable counter per directory. Update all `import`/package references and the
  build file (`pom.xml`/`build.gradle`) module names so it still compiles.
- Files **not** on the failure path: leave as-is to minimize churn (but rename the
  top-level module dir if its name is a giveaway like `hadoop-hdfs`).
- Record original→new path in `private/anonymization_map.json`.

**Log/print statement rewriting.**
- Find every `log.*`, `LOG.*`, `logger.*`, `print*`, `System.out/err`, `printf`, etc.
  call on the failure path **whose output appears in the symptom log** (grep the log for
  each string to confirm visibility).
- Replace the string **literal only**, keeping all format specifiers (`{}`, `%s`, etc.)
  and argument lists intact, so the runtime still emits the same structure. Use neutral
  unique tokens: `log.error("Failed to replicate block {}", b)` →
  `log.error("Event A7: {}", b)`. Each rewritten statement gets a distinct token so the
  log lines are still distinguishable and the LLM can correlate log→code.
- Do **not** change log levels, exception types, or stack-trace class names *unless* a
  class name directly reveals the bug (then also rename that class). Exception class names
  in stack traces are part of the symptom; renaming them is allowed if you also rename
  the class in source and update the map.
- Rebuild and re-run `reproduce.sh`; confirm the new log tokens appear.

**Verification (do not skip).**
- `grep -Ff <(jq -r '.strings[].original' private/anonymization_map.json) -r source/`
  must return **nothing** (no original strings remain in source).
- The anonymized `symptom.log` must still reproduce and contain the new tokens.
- The anonymized tree must still compile.

---

## 7. The diagnosis helper (`context/run_diagnosis.sh`)

`run_diagnosis.sh <BUG_DIR>` runs the 5 diagnoses. It:
- mounts `<BUG_DIR>` read-only at `/bug` inside a restricted network,
- sets egress to **api.anthropic.com:443 only** (iptables DROP default + ACCEPT for the
  API + established connections),
- invokes `claude -p "<prompt>"` once per run with
  `--disallowedTools WebFetch,WebSearch` and no MCP web tools,
- writes each run's full output to `diagnosis/run_N.md`,
- requires `--cap-add=NET_ADMIN` on the docker run (documented in §11).

The prompt is assembled from `symptom.md` + the fixed template in §5/M6. The script is
idempotent: a run whose `run_N.md` already exists and is non-empty is skipped on re-entry.

---

## 8. Grading rubric (precise)

A run **PASSes** iff its single-turn answer contains:
1. The **exact root-causing line(s)** — the same code locations the fix changed
   (match by anonymized file name + code identity, not by line number), **and**
2. The **exact logical condition/branch** that is wrong on the failure path (the `if`/loop
   guard whose logic the fix corrected, stated precisely).

Partial credit is **not** a pass. "Right file, wrong line" = FAIL. "Right line, no branch
condition" = FAIL. "Right branch but wrong line" = FAIL. Ambiguous or hedged answers with
no concrete lines = FAIL. Record the justification in the grade JSON so the result is
auditable.

---

## 9. Idempotency & resumption rules

- **Resume:** always start by reading `state.json` + `PROGRESS.md`. Resume at the first
  `PENDING` milestone after the highest `DONE`. If a milestone is `IN_PROGRESS` when you
  arrive, treat its prior work as **not trusted**: inspect its artifacts; if they are
  complete and valid, mark it `DONE`; if not, redo it from a clean state.
- **Redoing a DONE milestone** is allowed only if you find its artifacts are corrupted or
  wrong. In that case: set it back to `PENDING`, record *why* in the log, and re-run. Never
  silently overwrite `DONE` work.
- **Atomic writes:** every `state.json` update uses the temp-file-then-`mv` pattern (§4).
- **Determinism within a run:** do not set seeds or rely on `Date.now()` in scripts; shell
  `date` is fine for timestamps.
- **Single owner:** before starting, check no other agent has the bug `IN_PROGRESS`
  (look at the latest `by` field and the log). If a stale `IN_PROGRESS` is older than
  ~30 min with no heartbeat, claim it (record the takeover in the log).

---

## 10. Edge cases / FAQ

- **Build OOMs / takes hours:** build only the failure-path module + deps. Note it.
  If even that fails, M2 → `BLOCKED`.
- **Bug won't reproduce:** M3 → `BLOCKED` with full commands+output. Do not fabricate a
  reproduction. A blocked bug is still a valid data point (report it in summary).
- **The symptom log is huge:** that's expected — the diagnosis LLM gets the *path* to
  the log and uses `grep`/`less`; it does not load the whole file into context. Keep the
  full log; do not truncate.
- **Anonymization breaks the build:** minimize scope — only rename/rewrite what is on the
  failure path and visible in the log. Leave everything else untouched.
- **The fix touches multiple files/branches:** ground truth lists all of them; a run must
  name all to PASS.
- **Is the API call "internet"?** No. Diagnosis egress is restricted to `api.anthropic.com`
  only. The "no internet" rule means the model cannot fetch external pages, search, or
  reach its training corpus; it must reason from the provided files.

---

## 11. Docker (run inside the container, never on bare metal)

Build once:

```bash
cd /mnt/SSD-4T/ycx/CLODS
docker build -t clods-eval -f context/Dockerfile .
```

The image (Ubuntu 22.04 + JDK 11/17, Maven, Gradle, Python 3, git, ripgrep, jq, less,
Node + Claude Code CLI) provides the toolchain for every system. Add system-specific deps
by extending the Dockerfile or `apt install` at M2 (record it).

**Setup phase (M0–M5):** network on.

```bash
docker run --rm -it \
  -v /mnt/SSD-4T/ycx/CLODS:/work \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  clods-eval bash
# inside: cd /work/evaluations/<SYSTEM>/<BUGID> and follow M0–M5
```

**Diagnosis phase (M6):** network locked to the API only.

```bash
docker run --rm --cap-add=NET_ADMIN \
  -v /mnt/SSD-4T/ycx/CLODS/evaluations/<SYSTEM>/<BUGID>:/bug:ro \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --entrypoint /opt/clods/run_diagnosis.sh \
  clods-eval /bug
```

The entrypoint applies the iptables allowlist before launching Claude Code, so even if a
web tool slipped through, egress would be dropped. Grading (M7) and summary (M8) run with
no network.

---

## 12. Concrete end-to-end example (HDFS-11896, illustrative)

```bash
BUG_DIR=/mnt/SSD-4T/ycx/CLODS/evaluations/HDFS/HDFS-11896
mkdir -p $BUG_DIR/{private,source,logs,diagnosis}
cd $BUG_DIR

# M1
git clone https://github.com/apache/hadoop.git /work/repos/hadoop
cd /work/repos/hadoop
# locate fix commit from the JIRA's "Fix Version" / PR; e.g.:
FIX=$(git log --oneline --grep=HDFS-11896 | head -1 | awk '{print $1}')
PRE=$(git rev-parse $FIX^)
git show $FIX > $BUG_DIR/private/fix.diff
# record FIX, PRE in state.json

# M2
git checkout $PRE
mvn -pl hadoop-hdfs-project/hadoop-hdfs -am package -DskipTests

# M3  (write reproduce.sh; run it; check logs/symptom.log)
# M4  (anonymize per §6; rebuild; re-run reproduce.sh; commit in source/)
# M5  (write symptom.md; derive private/ground_truth.md; verify)
# M6  (run context/run_diagnosis.sh $BUG_DIR  -> 5 runs)
# M7  (grade each vs ground truth)
# M8  (write summary.md; set state.json.result)
```

---

## 13. When you finish

1. Ensure every milestone is `DONE` or `BLOCKED` (none `IN_PROGRESS`/`PENDING`).
2. Ensure `state.json` and `PROGRESS.md` agree.
3. Ensure `summary.md` exists with the `successes/5` and the discussion paragraph.
4. Leave the folder clean: only documented artifacts, no stray scratch files.
5. Your final message to the operator states: bug id, final status, successes/5.