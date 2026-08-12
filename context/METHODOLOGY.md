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

### Your only input
The **single input** you receive for a bug is its **JIRA ticket** (e.g. `HDFS-11896`).
From that ticket alone you derive everything else — the system repo, the fix commit, the
pre-fix commit, the symptom, and the failure path. No other hand-off is provided. Your job
is to perform **every** step below starting from that one ticket.

For your assigned bug you will, in order:

1. From the JIRA ticket, find the fix commit and the commit *just before* it (pre-fix).
2. **Clone the repo and build from source at the pre-fix commit** — do NOT use a released
   binary. You need a from-source build because (a) the bug may not be reproducible from a
   prebuilt binary, and (b) you must edit the source itself (rename files, rewrite log
   statements on the failure path) at M4. Some bugs are ~10 years old, so the build may
   break on a modern toolchain — **fix dependencies as needed** (see M2) and record every
   fix.
3. Reproduce the failure (real-system run, or a unit test if a full run is impractical).
4. **Anonymize** minimally: keep the real system source and the real reproduction log, but
   (a) never expose the **JIRA bug id** in any LLM-facing artifact, (b) redact only
   log/stack-trace text that the **JIRA report itself** quotes/attaches (nothing to redact
   if the ticket has no such text), and (c) rename the **distinctive bug-naming term(s)**
   (e.g. the `nonDfsUsed` metric) to a neutral equivalent. Do **not** hide the system —
   `datanode`, `namenode`, `block`, class names, etc. stay. Commit it.
5. Run the LLM diagnosis **5 times**, independently, with internet blocked and a
   single fixed prompt. No follow-up prompts.
6. Grade each of the 5 runs against ground truth (did it name the exact lines + branches?).
7. Record everything in a milestone-tracker file so any agent can resume your work.

You do NOT need internet during diagnosis. You DO need it for clone/build/reproduce.
**You run on the host** (a Claude Code session in the repo root, where your git
credentials and `ANTHROPIC_API_KEY` already work), and you spin up **disposable Docker
containers** for the per-bug build/reproduce/diagnose steps (see §11) — this is
deliberate: each bug lives on a different version of the system with a different
dependency set, and the container lets you install exactly the toolchain/dependencies that
bug needs without polluting the host or another bug's environment. Per-milestone git
commit/push happens on the host.

---

## 1. Glossary

| Term | Meaning |
|---|---|
| **bug** | One failure in one system, identified by a bug id (e.g. `HDFS-11896`). |
| **JIRA ticket** | The **only** input an agent receives for a bug. Everything else (repo, commits, symptom, failure path) is derived from it. |
| **fix commit** | The upstream commit that fixed the bug. |
| **pre-fix commit** | The parent of the fix commit (the last commit where the bug exists). This is what you check out. |
| **failure path** | The chain of code locations from the logged symptom down to the root cause (the call stack visible in the symptom log + the lines the fix changed). |
| **symptom** | The **externally visible** failure an operator observes — a wrong value, an error message, an exception, or a hang. It is **only what is observed**, never the trigger or mechanism that causes it. `symptom.md` states only this observable plus a pointer to where it shows up in `logs/symptom.log` (see M5). Stating the cause/trigger in `symptom.md` is **cheating** — it hands the diagnosis LLM the answer and the run is invalid. |
| **symptom log** | The log file produced when the bug is triggered. It is the *real* reproduction log — keep system identifiers as-is; only redact case-identifying strings (see anonymization). |
| **anonymization** | The **minimal** redaction that stops the LLM from recognizing the *specific JIRA case* (and recalling its known fix from memory). It is **not** about hiding the system. Concretely: (1) never expose the **JIRA bug id** (e.g. `HDFS-11896`) in any LLM-facing artifact; (2) replace any **log/stack-trace text that is quoted or attached in the JIRA report itself** with neutral tokens (if the ticket attaches no logs, no log redaction is needed); (3) rename the **one or few distinctive terms** that name the bug (e.g. the `nonDfsUsed` metric) to a neutral equivalent. General system identifiers (class names, `datanode`, `namenode`, `block`, `FSNamesystem`, …) are **kept** — it is fine for the LLM to know it is HDFS. |
| **ground truth** | The exact line(s) and branch condition(s) the real fix touched. Derived from the fix-commit diff. Used only for grading, **never** shown to the diagnosis LLM. |
| **run** | One independent LLM diagnosis attempt. 5 runs per bug. |

---

## 2. Directory layout & paths

All work lives under `/mnt/SSD-4T/ycx/CLODS/`. The layout is:

```
CLODS/
├── context/
│   ├── METHODOLOGY.md            # this file
│   ├── prompt.md                 # ★ the kickoff prompt an operator hands to an agent
│   ├── Dockerfile
│   └── run_diagnosis.sh          # helper for the 5x network-locked diagnosis
└── evaluations/                  # live per-bug progress IS tracked here (see .gitignore)
    ├── COORDINATION.log          # ★ shared append-only coordination log (flock; never overwrite)
    ├── EXAMPLE/bug-1/            # published illustrative example (see its README)
    ├── repos/                    # [gitignored, heavy] per-bug scratch clones: <SYSTEM>-<BUGID>
    └── <SYSTEM>/                 # e.g. HDFS, Presto, Blink, Velox
        └── <BUGID>/              # e.g. HDFS-11896
            ├── PROGRESS.md       # ★ milestone tracker (source of truth for resume)
            ├── state.json        # ★ machine-readable mirror of PROGRESS milestones
            ├── reproduce.sh      # system-specific script that reproduces the bug (you write it)
            ├── reproduce.md      # ★ human-readable write-up of the reproduction (for operator review)
            ├── private/          # NEVER given to the diagnosis LLM
            │   ├── ground_truth.md       # exact lines+branches the fix changed
            │   ├── anonymization_map.json # original→anonymized file/string mapping
            │   ├── fix.diff                 # the raw fix-commit diff
            │   ├── deps-fix.patch           # build-file edits made to compile the old pre-fix tree
            │   └── symptom.orig.log         # [gitignored] pre-anonymization log
            ├── source/           # [gitignored, heavy] anonymized source tree (rebuild on resume)
            ├── logs/
            │   └── symptom.log   # [gitignored, heavy] anonymized symptom log given to the LLM
            ├── symptom.md        # the symptom description given to the LLM
            ├── diagnosis/
            │   ├── run_1.md ... run_5.md   # full raw output of each of the 5 runs
            │   └── run_1.grade.json ...   # per-run grading verdict
            └── summary.md         # final: successes/5 + discussion
```

**Tracked vs gitignored (important):** the **lightweight** per-bug files
(`PROGRESS.md`, `state.json`, `symptom.md`, `summary.md`, `reproduce.sh`, `reproduce.md`,
`diagnosis/*`, `private/*.md|.json|.diff|.patch`) are committed to this repo so multiple
agents can coordinate and resume. The **heavy / reproducible** artifacts are gitignored: `source/`
(the anonymized source tree — rebuild from `anonymization_map.json` + `deps-fix.patch` +
`pre_fix_commit`; see §9), `logs/` (symptom logs can be huge), and `repos/` (scratch
clones). The published example's small `symptom.log` is the one exception that is tracked.

**Path rule:** the `<SYSTEM>/<BUGID>` folder is created under `evaluations/`. The
published example lives at `evaluations/EXAMPLE/bug-1/`.

---

## 3. Milestones (the heart of resumability)

Work is split into ordered milestones **M0–M8**. Each milestone is atomic: it is either
`PENDING`, `IN_PROGRESS`, `DONE`, `BLOCKED`, or `FAILED`, **and** carries an explicit
`success: true|false|null` and an `outcome` token (see §4) so it is unambiguous whether
each step succeeded. **Rules:**

1. On startup, read `PROGRESS.md` + `state.json`. Find the highest-numbered `DONE`
   milestone. Resume at the next one. Never redo a `DONE` milestone (see exception in §10).
2. Before starting a milestone, set it to `IN_PROGRESS` and **atomically** rewrite
   `state.json` (write to a temp file in the same dir, then `mv` over the old one) so a
   kill mid-write cannot corrupt the tracker.
3. When a milestone finishes, set it to `DONE`, record artifacts (paths) and a one-line
   note. Append a timestamped line to the `## Log` section of `PROGRESS.md`.
4. Only **one** milestone may be `IN_PROGRESS` at a time.
5. If a milestone genuinely cannot be made to succeed (e.g. build won't compile, bug
   won't reproduce), set it to `FAILED` (`success: false`) with a precise reason, cascade
   the remaining milestones to `BLOCKED` (`success: null`), and stop. Do not silently
   skip ahead.
6. **Commit & push after every milestone.** As soon as a milestone is `DONE` (or `FAILED`),
   commit your bug-folder changes and push (§13 Git discipline). This is what makes a
   killed agent resumable by another. Never accumulate multiple milestones in one commit.
7. **Stay in your lane.** You own exactly one folder, `evaluations/<SYSTEM>/<BUGID>/`.
   Write only there. Never modify `context/`, `Dockerfile`, `example/`, the repo root, or
   any other bug's folder. Shared coordination is append-only via
   `evaluations/COORDINATION.log` (§13) — never overwrite it or anyone else's file.

| ID | Milestone | Network | Key outputs |
|---|---|---|---|
| M0 | Scaffold & claim the bug folder | — | folder, `PROGRESS.md`, `state.json` |
| M1 | From JIRA ticket: identify fix commit + pre-fix commit | on | `fix.diff`, bug metadata in `state.json` |
| M2 | Check out pre-fix, **build from source**, fix old deps as needed | on | built source tree, `private/deps-fix.patch` |
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

**Per-step success is explicit and greppable.** Every milestone carries:
- `status` — `PENDING` | `IN_PROGRESS` | `DONE` | `BLOCKED` | `FAILED`
- `success` — `true` | `false` | `null`. **`DONE` ⇒ `success: true`; `FAILED` ⇒
  `success: false`; `BLOCKED` ⇒ `success: null`.** `FAILED` = this step was attempted and
  could not be made to succeed (build won't compile, bug won't reproduce, anonymization
  irrecoverably breaks the build). `BLOCKED` = not attempted because an earlier milestone
  `FAILED` (cascading — not a fresh attempt).
- `outcome` — machine token: `success` | `failed` | `blocked` | `pending` | `in_progress`.

This makes "did each step succeed?" trivially auditable across all bugs, e.g.
`jq '[.milestones[] | {id, outcome, success}]' state.json`.

`state.json` schema:

```json
{
  "bug_id": "HDFS-11896",
  "system": "HDFS",
  "jira": "HDFS-11896",
  "source_repo": "https://github.com/apache/hadoop.git",
  "fix_commit": "<sha>",
  "pre_fix_commit": "<sha>",
  "anonymized_commit": "<sha in a fresh local repo>",
  "symptom_short": "<one-line symptom>",
  "milestones": [
    {"id": "M0", "status": "DONE", "outcome": "success", "success": true,  "started": "...", "finished": "...", "attempts": 1, "by": "agent-run-<id>", "artifacts": ["..."], "note": "..."},
    {"id": "M1", "status": "DONE", "outcome": "success", "success": true,  "...": "..."},
    {"id": "M2", "status": "IN_PROGRESS", "outcome": "in_progress", "success": null, "...": "..."},
    {"id": "M3", "status": "PENDING",  "outcome": "pending", "success": null, "...": "..."},
    {"id": "M4", "status": "PENDING",  "outcome": "pending", "success": null, "...": "..."},
    {"id": "M5", "status": "PENDING",  "outcome": "pending", "success": null, "...": "..."},
    {"id": "M6", "status": "PENDING",  "outcome": "pending", "success": null, "...": "..."},
    {"id": "M7", "status": "PENDING",  "outcome": "pending", "success": null, "...": "..."},
    {"id": "M8", "status": "PENDING",  "outcome": "pending", "success": null, "...": "..."}
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

### M1 — Identify commits (input: the JIRA ticket)
1. Your **only** input is the JIRA ticket. From it, identify the system repo URL and the
   fix commit (the commit whose diff resolves the ticket). If the ticket references a PR,
   use the PR's merge commit as the fix commit.
2. In a **per-bug scratch clone** of the system repo at `/work/repos/<SYSTEM>-<BUGID>`
   (container path = host `repos/<SYSTEM>-<BUGID>`, gitignored), confirm the fix commit
   resolves the described symptom by reading its diff. Use a **per-bug** clone so two
   agents working the same system never share/clobber one checkout.
3. `pre_fix_commit = git rev-parse <fix_commit>^` — the last commit where the bug exists.
4. Save `git show <fix_commit> > <BUG_DIR>/private/fix.diff`.
5. Record `jira`, `source_repo`, `fix_commit`, and `pre_fix_commit` in `state.json`.
   Mark M1 `DONE`, `success: true`.

### M2 — Check out pre-fix & build from source
1. In the scratch repo: `git checkout <pre_fix_commit>`.
2. **Build from source**, not a released binary — you must be able to edit and rebuild the
   source at M4. Use the system's build (`mvn -pl <module> -am package -DskipTests`,
   `./gradlew build -x test`, etc.). Record the exact build command in `PROGRESS.md`.
3. **Fix dependencies as needed.** Many bugs are ~10 years old and their builds break on a
   modern toolchain (wrong JDK, removed/404 Maven repos, expired certs, changed plugin
   versions). This is expected. Inside the container you can `apt-get install` the right
   JDK/toolchain and pin specific dependency/plugin versions to make the old build work.
   **Record every dependency fix** (what you changed and why) in `PROGRESS.md`, and save
   any build-file edits as `private/deps-fix.patch`. The goal is a reproducible from-source
   build of the pre-fix tree — not a faithful historical build.
4. If the build is intractably large, build **only the module(s) on the failure path**
   plus their dependencies. Note exactly what you built.
5. Capture the build command (and any dep-fix steps) in `reproduce.sh` so M3/M4 reuse it.
6. Mark M2 `DONE`, `success: true`, with the built artifact paths. If the build genuinely
   cannot be made to compile, set M2 `FAILED` (`success: false`, `outcome: "failed"`) with
   the exact errors and stop — a bug you cannot build cannot be anonymized or diagnosed.

### M3 — Reproduce the failure
The symptom log the LLM later sees **must be the system's own log output**, produced by
exercising the real system — never a narrative you inject. This is the integrity crux of
the whole experiment: an added log line that reports internal state (a counter value, a
per-stage probe) hands the model the answer and invalidates the run.

1. Write `reproduce.sh`: a self-contained script that (a) builds if needed, (b) runs the
   real system or a targeted unit test, and (c) writes the resulting log to
   `<BUG_DIR>/private/symptom.orig.log`. Prefer the real failing operation; fall back to a
   unit/integration test only if a full cluster run is impractical, and say so in the note.
2. **Always run with verbose logging turned up to DEBUG** (root logger or at least the
   subsystem packages on the failure path), so the symptom log is a rich, realistic trace.
3. **Exercise the system with normal operations** — real reads/writes/RPCs — and, where
   feasible, a **stress workload (e.g. YCSB)**, so the log reflects genuine activity, not a
   bare trigger. The failure path should be reached through ordinary use. A **large,
   production-like log is desirable, not a problem** — verbose DEBUG plus real traffic
   yields a symptom log that resembles what an operator would actually collect in
   production; do not trim it down for size (the diagnosis LLM greps it, it does not load
   it whole).
4. **Do NOT add any log or print statement** to the production code *or* the test/harness to
   expose internal state. No `System.out.println`, no per-stage "PROBE"/metric dumps, no
   "this is wrong" markers. Detect that the bug reproduced with a **test assertion**
   (its output goes to the test runner, **not** into `symptom.orig.log`), or by reading the
   system's own reporting surface.
5. **Observing a non-log symptom.** Some bugs (e.g. a wrong in-memory metric) are not visible
   in any log line. Then, and only then, capture the symptom from the **system's own reporting
   surface** (JMX / an admin report / the web UI / metrics endpoint) — that is real system
   output, not an injected log — and/or state it in `symptom.md`. What you state is the
   *observable* (the final wrong value the user sees), **never** the per-stage internal
   breakdown that reveals the mechanism. **This is the same anti-cheat rule M5 step 1 +
   step 3 enforce on `symptom.md`** (the "bare observable + log pointer, nothing else" gate):
   when you later write `symptom.md` at M5, a non-log symptom is stated as the single wrong
   value the operator reads (e.g. "the other-used metric is doubled") — never the trigger,
   the mechanism, or a "what stays correct" comparison.
6. Run it. Confirm the symptom reproduced (via the assertion / the reporting surface). Keep
   the full verbose log as `private/symptom.orig.log` (M4 anonymizes it into
   `logs/symptom.log`).
7. **Write `<BUG_DIR>/reproduce.md`** — a concise, human-readable write-up so the operator
   can review *how* the bug was reproduced without re-reading the code. It must cover:
   - the exact scenario and the command(s) to run (mirroring `reproduce.sh`);
   - how the failure is **triggered** (the real code path the scenario drives) and how it is
     **detected** (the silent assertion / the reporting surface, with the concrete
     observed-vs-expected values);
   - the captured log: path, size, and that it is the system's own DEBUG output with **no
     injected/answer-revealing lines**;
   - any **test-only infrastructure** changes and why (e.g. a value a simulator must report,
     reflection to toggle a flag) — anything that is not the pristine production path, stated
     plainly for auditing;
   - honest caveats (e.g. minicluster vs full production cluster).
   Keep it factual and reviewable; it is committed (lightweight) alongside `reproduce.sh`.
8. Mark M3 `DONE`, `success: true`. If the bug does not reproduce after genuine effort,
   set M3 `FAILED` (`success: false`, `outcome: "failed"`) with the exact commands tried
   and outputs, cascade the remaining milestones to `BLOCKED`, and stop.

### M4 — Anonymize (minimal, case-identifying only)
Goal: stop the LLM from recognizing the **specific JIRA case** (and recalling its known fix
from memory) — **not** to hide the system. Keep the real system source and the real
reproduction log; the LLM may know it is HDFS. See §6 for the full procedure.

1. Populate `<BUG_DIR>/source` with the **real** failure-path source (the actual files from
   the pre-fix tree — keep `datanode`/`namenode`/`block`/class names). Apply only:
   - **Bug-id scrub:** ensure the JIRA id (e.g. `HDFS-11896`, `11896`) appears **nowhere**
     in `source/` or `logs/symptom.log`.
   - **Distinctive-term rename:** rename the one/few terms that *name* the bug (e.g. the
     `nonDfsUsed` metric → a neutral name such as `otherUsed`) consistently across `source/`
     and the symptom log. Record every rename in `private/anonymization_map.json`.
   - **JIRA-quoted text redaction:** if (and only if) the JIRA report quotes/attaches a
     log or stack trace, replace those specific strings with neutral tokens. If the ticket
     attaches no logs, the symptom log needs **no** redaction — use it as-is.
2. Use the **real reproduction log** from M3 as `logs/symptom.log` (system identifiers kept).
   If a distinctive term was renamed in `source/`, apply the same rename to the log so the
   two stay consistent. Re-running `reproduce.sh` to regenerate it is fine but not required
   when the only change is a mechanical term rename.
3. Keep a committed, deterministic way to regenerate the (gitignored) `source/` + symptom
   log on resume — either a fresh local git repo at `<BUG_DIR>/source` (`git init`; record
   the hash as `anonymized_commit`) **or** a committed `private/` copy + a replay script.
4. Mark M4 `DONE`, `success: true`.

### M5 — Prepare diagnosis inputs & ground truth
1. Write `symptom.md` = **the bare observable + a pointer to the log, nothing else.**
   This is the most validity-critical artifact: if `symptom.md` already explains the cause,
   the diagnosis run is a **cheat**, not a measurement of the LLM's reasoning.

   **It must contain only:**
   - (a) the externally-visible failure an operator sees (a wrong value / error string /
     exception / hang), in **≤2 sentences**; and
   - (b) a pointer to where it shows up in `logs/symptom.log` (a line reference, or a marker
     token you inserted at M4 such as `>>> SYMPTOM`, or "the log for this run is
     `logs/symptom.log`" when the symptom is not itself a single log line).

   **It must NOT contain:** the trigger; the mechanism/causal chain; the at-fault
   component, class, method, or branch; the buggy overload/operation/path that selects the
   failure; the fix or any hint toward it; the JIRA bug id; or any **narrowing comparison
   that implies the cause** (e.g. "only the other-used metric is wrong; capacity and
   dfs-used stay correct" — that tells the LLM exactly which metric to blame).

   The LLM is given `source/` + the log + this `symptom.md` and must derive the root cause
   itself. Naming the system (HDFS) or general structural terms (datanode, block) is fine;
   use the neutral name for any distinctive term you renamed in M4 (e.g. `otherUsed`) *only
   if that term is itself the observable surface* (e.g. the metric an operator reads).

   **Self-audit before marking M5 done** — re-read `symptom.md` and ask, sentence by
   sentence: *"does this state the **cause/trigger**, or only the **observable**?"* Delete
   any sentence that states or implies the cause.

   **Correct (minimal) examples — `symptom.md` is the ONE thing an operator would paste to
   a colleague to say "something is wrong":**
   - *Wrong-value bug (HDFS-11896):* "The NameNode's other-used space metric is **doubled**
     (reported ~2× the true value). The log for this run is `logs/symptom.log`. Identify the
     root cause from the source code and the log. Do not assume any known fix."
     (Use the **renamed** term — `other-used` — that appears in the anonymized `source/` +
     log, not the real `non-dfs` term, so the LLM can map it without recognizing the JIRA
     case. "Doubled" is the *observable*; it does not reveal *why* it doubles.)
   - *Exception/error bug (Zookeeper-1851):* paste the **exact exception/stack trace as the
     log prints it** (the `ConnectionLoss` + its stack from `logs/symptom.log`), and nothing
     else — no "three-member ensemble," no "the `create(...,Stat)` overload," no "the
     follower then stops serving everyone" timeline. Those are the cause.

   **Rule of thumb:** `symptom.md` = a wrong number, or a pasted stack trace. **Do not
   throw the JIRA case's information into the symptom** — not the trigger, not the sequence
   of events, not the "what stays correct" comparison, not the failing overload/path. All
   of that is the *cause* and belongs only in `private/ground_truth.md`.

   **Forbidden (cheating) version of the HDFS case — do NOT write this:**
   > A DataNode stops heartbeating, is declared dead, then comes back and **re-registers**.
   > From that point the metric is too high… Capacity and DFS-used totals remain correct;
   > only the other-used metric is wrong.

   "re-registers" / "dead node" / "only other-used is wrong" are the **trigger and the
   location** — the root cause — not the symptom. (This was the real failure in the first
   HDFS-11896 run; do not repeat it. The Zookeeper equivalent — naming the
   `create(...,Stat)` overload as the failing call — is the same anti-pattern: that
   overload is the trigger path, i.e. the cause.)
2. Derive `private/ground_truth.md` from `private/fix.diff`: list the **exact file:line(s)**
   the fix changed and the **exact branch/condition** that was wrong (before the fix), using
   the real class/method names (they are kept in `source/`) and the renamed distinctive term.
   This is the answer key. It lives only in `private/`.
3. **Cause-leak verification (the anti-cheat gate).** This is separate from the anonymization
   grep and is the one that actually catches the HDFS-11896 / Zookeeper-1851 failure mode.
   Re-read `symptom.md` and assert **all** of:
   - **Anonymization grep:** `source/`, `logs/symptom.log`, and `symptom.md` contain **no
     JIRA bug id** and none of the distinctive terms you renamed (grep the bug id and each
     renamed term; expect zero hits). General system identifiers are expected and fine.
   - **No cause-leak:** `symptom.md` states only the observable (a wrong value or a pasted
     stack) + the log pointer. It contains **no** trigger, no mechanism/timeline, no
     at-fault component/class/branch, no buggy overload/path, and no "what stays correct"
     narrowing comparison. If it does, **delete that content** — the run is invalid until it
     is gone (this is exactly the cheat the first HDFS-11896 / Zookeeper-1851 runs hit).
   - **No JIRA-case narrative:** nothing in `symptom.md` was copied from the JIRA ticket's
     description/timeline/attachments beyond the bare observable. (For an exception bug the
     pasted stack comes from `logs/symptom.log`, **not** from the JIRA attachment — the log
     is the system's own output, the JIRA text is the author's analysis.)
   If any check fails, fix `symptom.md` and re-run this step before marking M5 done.
4. Mark M5 `DONE`, `success: true`.

### M6 — Run LLM diagnosis ×5 (network locked, single prompt, no follow-ups)
1. Use `context/run_diagnosis.sh` (§7). It runs the diagnosis **5 times**, each in a
   fresh, stateless process, with web tools denied and egress restricted to the Anthropic
   API only. It stages only `symptom.md` + `source/` + `logs/symptom.log` (never
   `private/`), pins `--model claude-opus-4-7 --effort high` (Opus 4.7), and writes `diagnosis/run_N.md`.
2. The **exact prompt** (the script substitutes the staging paths for you):

   ```
   Given the source code at <STAGE>/source and the symptom logs located at <STAGE>/logs/symptom.log,
   what is the root cause of the failure: <SYMPTOM from symptom.md>?
   Identify the specific lines of code and the exact logical conditions (branches) that
   dictate this failure path.

   IMPORTANT: Do NOT connect to the internet or find other bugs with a similar symptom.
   Instead rely purely on your reasoning to diagnose this failure.
   ```

   `<SYMPTOM>` = the full text of `symptom.md`. `<STAGE>` = the throwaway staging dir
   (so the agent never sees `/bug` or `private/`). Do not edit this prompt per bug.
3. **No follow-up prompts.** Whatever the model returns in that single turn is the run's
   answer. Do not iterate, clarify, or hint.
4. Mark M6 `DONE`, `success: true`.

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
3. Mark M7 `DONE`, `success: true`.

### M8 — Summary & finalize
1. Compute `successes = count(PASS)` out of 5. Write `summary.md`:
   - the bug id, system, symptom,
   - successes/5,
   - per-run verdict table,
   - a 3–6 sentence discussion: did the LLM isolate the root cause *deterministically*
     (all/most runs PASS) or not? Tie back to whether LLMs can bypass deterministic tools
     or need something like CLODS to ground reasoning.
2. Set `state.json.result` and mark M8 `DONE`, `success: true`.

---

## 6. Anonymization procedure (detail)

**Principle.** Anonymization here is *minimal and case-targeted*. The threat is the LLM
recognizing the exact JIRA case ("oh, this is HDFS-11896, the fix is in `resetBlocks`") and
regurgitating the known fix instead of reasoning. It is **not** about disguising the system.
So: keep the real source, keep the real class/log identifiers, keep the fact that it is
HDFS — and remove only the handful of things that pin the *specific* ticket.

Inputs: the real failure-path source (files named in the fix diff + files in the symptom-log
stack trace) and the real M3 reproduction log. Outputs: `source/` = real failure-path files
with the redactions below; `logs/symptom.log` = the real reproduction log with the same
redactions.

**(a) Bug-id scrub (always).**
- The JIRA id and its bare number (`HDFS-11896`, `11896`) must appear **nowhere** in
  `source/`, `logs/symptom.log`, or `symptom.md`. Real source rarely contains it; check anyway.

**(b) Distinctive-term rename (usually one or a few).**
- Identify the term(s) that *name* the bug — the thing a reader would grep to recall the
  ticket. For HDFS-11896 that is the `nonDfsUsed` metric (title: "Non-dfsUsed will be
  doubled …"). Rename it and its obvious variants (`nonDfsUsed`, `NonDfsUsed`, `NonDFSUsed`,
  `getNonDfsUsed`, `capacityUsedNonDfs`, `getNonDfsUsedSpace`, …) to a neutral but plausible
  equivalent (e.g. `otherUsed` / `getOtherUsed` / `getOtherUsedSpace`) **consistently** across
  `source/` and the symptom log. Record every rename in `private/anonymization_map.json`.
- Leave everything else — `datanode`, `namenode`, `block`, `DatanodeDescriptor`,
  `HeartbeatManager`, `FSNamesystem`, package paths — **unchanged**.
- You do **not** need to rename across the whole build tree (metric names are often
  proto-entangled); it is enough to rename within the curated failure-path files placed in
  `source/`, which the LLM reads but need not recompile. Reproduction was already proven on
  the real tree at M3.

**(c) JIRA-quoted-text redaction (only if applicable).**
- If the JIRA report quotes or attaches a log snippet / stack trace, replace those *specific
  reported strings* with neutral tokens (so the LLM can't string-match the ticket). If the
  ticket attaches no logs — as with HDFS-11896 — there is **nothing to redact** in the log;
  use the real reproduction log as-is (apply only the (b) rename for consistency).

**Verification (do not skip).**
- `grep -RnE 'HDFS-11896|\b11896\b' source/ logs/symptom.log symptom.md` → **zero hits**.
- `grep -RnwF '<each original distinctive term>' source/ logs/symptom.log` → **zero hits**
  (they were renamed). General system identifiers are expected and are fine.
- The symptom log is the real reproduction log (system identifiers intact, bug-id absent).

---

## 7. The diagnosis helper (`context/run_diagnosis.sh`)

`run_diagnosis.sh <BUG_DIR>` runs the 5 diagnoses. It:
- sets egress to **api.anthropic.com:443 only** (iptables DROP default + ACCEPT for the
  API + established connections); requires `--cap-add=NET_ADMIN` on the docker run (§11);
- builds a **throwaway staging dir** containing **only** `symptom.md`, `source/`, and
  `logs/symptom.log`, and runs the agent from there — `private/` (answer key, fix diff,
  anonymization map) is **never** copied in, so it is unreachable regardless of the mount;
- invokes `claude -p "<prompt>"` once per run — each a **fresh, stateless process** (no
  `--continue`/`--resume`), so no conversation history or orchestrator context leaks in;
- pins the subject: `--model "$CLODS_MODEL"` (default `claude-opus-4-7`, i.e. Opus 4.7) and `--effort "$CLODS_EFFORT"`
  (default `high`), matching the paper's "Claude Opus 4.7, thinking=high"; override per run via
  env only if you intentionally change the subject;
- hardens the session: `--bare` (skip CLAUDE.md auto-discovery, auto-memory, plugins,
  hooks, keychain — no project/user memory leaks in), `--no-session-persistence`,
  `--exclude-dynamic-system-prompt-sections`;
- denies non-essential tools: `--disallowed-tools 'Bash,Write,Edit,WebFetch,WebSearch,
  Task,NotebookEdit'` — the agent can only Read/Grep/Glob the staging tree; it cannot shell
  out, go online, modify files, or spawn sub-agents;
- writes each run's full output to `diagnosis/run_N.md` (needs the bug dir mounted
  read-write; see §11).

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
- **Reconstructing `source/` & `logs/` on resume (they are gitignored):** a resuming agent
  finds the bug folder in git but NOT the `source/` tree or `logs/`. Rebuild them
  deterministically from the tracked metadata: clone the system repo at `pre_fix_commit`,
  apply `private/deps-fix.patch`, replay `private/anonymization_map.json` (rename files +
  rewrite log strings) to regenerate `source/`, then re-run `reproduce.sh` to regenerate
  `logs/symptom.log`. Only if the metadata is insufficient to reconstruct should you redo
  M2–M4 from scratch.
- **Atomic writes:** every `state.json` update uses the temp-file-then-`mv` pattern (§4).
- **Determinism within a run:** do not set seeds or rely on `Date.now()` in scripts; shell
  `date` is fine for timestamps.
- **Single owner:** before starting, check no other agent has the bug `IN_PROGRESS`
  (look at the latest `by` field and the log). If a stale `IN_PROGRESS` is older than
  ~30 min with no heartbeat, claim it (record the takeover in the log).

---

## 10. Edge cases / FAQ

- **Build OOMs / takes hours:** build only the failure-path module + deps. Note it.
  If even that fails, M2 → `FAILED` (`success: false`) and cascade.
- **Build is from 10 years ago and breaks on modern tools:** expected — fix the deps
  (pin JDK/Maven/plugin versions, swap dead repos), save the edits as
  `private/deps-fix.patch`, record them in `PROGRESS.md`. Only `FAILED` if you cannot get
  the pre-fix tree to compile after genuine effort.
- **Bug won't reproduce:** M3 → `FAILED` (`success: false`) with full commands+output. Do
  not fabricate a reproduction. A failed-reproduction bug is still a valid data point
  (report it in summary).
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

## 11. Docker (per-bug containers, never on bare metal)

**You (the agent) run on the host** in a Claude Code session, where your git/GitHub
credentials and `ANTHROPIC_API_KEY` already work — so per-milestone `git commit`/`push`
(§13) happens on the host with no credential gymnastics. You spin up **disposable
`clods-eval` containers** only for the per-bug steps that need the system's toolchain
or network isolation. Each bug lives on a different version of the system and needs a
different dependency set (an old Hadoop needs JDK 7 + a pinned Maven 3.2; a newer one
needs JDK 11; a C++ system needs a specific gcc/boost; etc.), so the base image is just a
common starting point and you **extend it per bug** at M2. Nothing one bug installs can
break another bug's build — that is the whole reason for Docker rather than bare metal.

Build the base image once (host):

```bash
cd /mnt/SSD-4T/ycx/CLODS          # repo root; $PWD throughout this section
docker build -t clods-eval -f Dockerfile .
```

The base image is Ubuntu 22.04 + JDK 11/17, Maven, Gradle, Python 3, git, ripgrep, jq,
less, iptables/iproute2, and Node + Claude Code CLI.

**Build & reproduce (M2–M4):** network on, repo mounted at `/work`. The agent issues
this from the host; the container does the compile and runs `reproduce.sh`, writing the
failure log into the mounted repo (gitignored `logs/`).

```bash
docker run --rm -v "$PWD:/work" clods-eval bash -lc '
  cd /work/repos/<SYSTEM>-<BUGID> && <build cmd>          # M2
  bash /work/evaluations/<SYSTEM>/<BUGID>/reproduce.sh    # M3
'
```

For a heavy/deterministic dep set, derive a per-bug image instead of `apt-get` inline,
and record every dependency added/pinned in `PROGRESS.md` + `private/deps-fix.patch` (M2):

```bash
docker build -t clods-eval:<SYSTEM>-<BUGID> - <<'EOF'
FROM clods-eval
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-7-jdk ...
EOF
# then use clods-eval:<SYSTEM>-<BUGID> in the build/reproduce and diagnose commands below
```

> File ownership: containers run as root, so files they write into the mounted repo
> (`source/`, `logs/`) are root-owned. That is fine — those paths are gitignored and
> rebuilt on resume (§9). If you prefer host-owned artifacts, add
> `--user "$(id -u):$(id -g)" -e HOME=/work` to the build/reproduce command (not the
> diagnose command — iptables needs root).

**Anonymize (M4):** rename files and rewrite log literals *on the host* (plain text edits
in the mounted `source/`), then rebuild + re-run inside a container to regenerate the
anonymized symptom log. Verify zero original-identifier leakage (§6).

**Diagnose (M6):** network locked to the API only. The entrypoint applies the iptables
allowlist before launching Claude Code, so even if a web tool slipped through, egress
would be dropped. The agent issues this from the host; outputs land in the mounted
`diagnosis/`. Mount the bug dir **read-write** (the script writes `diagnosis/run_N.md`)
— this is safe: `run_diagnosis.sh` stages only `symptom.md`+`source/`+`logs/` into a
throwaway dir and runs the agent there with `Bash`/`Write`/`Edit` denied, so the agent can
neither reach `private/` nor modify anything.

```bash
docker run --rm --cap-add=NET_ADMIN \
  -v "$PWD/evaluations/<SYSTEM>/<BUGID>:/bug" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --entrypoint /opt/clods/run_diagnosis.sh \
  clods-eval /bug
```

**Grade (M7) and summary (M8):** run on the host — no container, no network needed.

For the operator-facing end-to-end walkthrough (what to type into a fresh Claude Code
session), see `context/README.md`.

---

## 12. Concrete end-to-end example (HDFS-11896, illustrative)

The only input is the JIRA ticket `HDFS-11896`; everything below is derived from it.

```bash
BUG_DIR=/mnt/SSD-4T/ycx/CLODS/evaluations/HDFS/HDFS-11896
mkdir -p $BUG_DIR/{private,source,logs,diagnosis}
cd $BUG_DIR

# M1  (input = JIRA ticket HDFS-11896)
git clone https://github.com/apache/hadoop.git repos/hadoop-HDFS-11896
cd repos/hadoop-HDFS-11896
# from the ticket's "Fix Version"/PR, locate the fix commit; e.g.:
FIX=$(git log --oneline --grep=HDFS-11896 | head -1 | awk '{print $1}')
PRE=$(git rev-parse $FIX^)
git show $FIX > $BUG_DIR/private/fix.diff
# record jira, source_repo, FIX, PRE in state.json; M1 DONE success:true

# M2  (build from source at the pre-fix commit; fix old deps as needed)
git checkout $PRE
# this bug is old -> may need: apt-get install openjdk-7-jdk, pin maven/plugins,
# swap dead repositories. Save build-file edits to private/deps-fix.patch.
mvn -pl hadoop-hdfs-project/hadoop-hdfs -am package -DskipTests
# M2 DONE success:true (or FAILED if it won't compile, then cascade BLOCKED)

# M3  (write reproduce.sh; run it; check logs/symptom.log; save private/symptom.orig.log)
# M4  (anonymize per §6; rebuild; re-run reproduce.sh; commit in source/; record anon commit)
# M5  (write symptom.md; derive private/ground_truth.md; verify zero identifier leakage)
# M6  (run context/run_diagnosis.sh $BUG_DIR  -> 5 runs, network locked)
# M7  (grade each vs ground_truth.md -> run_N.grade.json)
# M8  (write summary.md; set state.json.result; M8 DONE success:true)
```

---

## 13. Workspace division, coordination & git discipline

Multiple agents work in this same workspace at once. Follow these rules so they don't
clobber each other.

### Workspace ownership
- You own exactly **one** folder: `evaluations/<SYSTEM>/<BUGID>/`. Create it at M0 and
  write only inside it. Everything you produce goes there.
- **Per-bug scratch clone:** `/work/repos/<SYSTEM>-<BUGID>` (host `repos/<SYSTEM>-<BUGID>`,
  gitignored). Never share a clone with another agent, even for the same system — the
  `-<BUGID>` suffix guarantees disjoint checkouts.
- **Read-only shared:** `context/`, `Dockerfile`, `example/`, and the repo root files. Do
  not edit, rename, or delete any of these. If the methodology or harness needs a change,
  stop and tell the operator — do not patch it yourself.
- **Never touch another agent's bug folder.** Read it only if you must coordinate; never
  write to it.

### The shared coordination log (append-only — never overwrite)
`evaluations/COORDINATION.log` is the one shared file. Every agent **appends** to it; no
one ever overwrites it. Use `flock` so concurrent appends don't corrupt each other:

```bash
append_coord() {  # usage: append_coord "M2 DONE success"
  flock evaluations/COORDINATION.log bash -c \
    "printf '%s %s %s\n' \"\$(date -u +%FT%TZ)\" \"\$BUGID\" \"\$1\"" \
    >> evaluations/COORDINATION.log
}
append_coord "claim M0"
append_coord "M2 DONE success"
append_coord "M3 FAILED: won't reproduce"
```

Append a line when you: claim a bug, start/finish a milestone, hit `FAILED`/`BLOCKED`, or
finish the bug. Your own per-bug log lives in `PROGRESS.md`'s append-only `## Log` section
— also append with `>>`, never overwrite with `>`.

### Git discipline — commit & push after every milestone
After **each** milestone is `DONE` (or `FAILED`), immediately commit and push so another
agent can resume your bug if you are killed:

```bash
cd /mnt/SSD-4T/ycx/CLODS          # repo root — git runs on the host (you are not in a container)
git pull --rebase origin main      # pick up other agents' commits first
git add evaluations/<SYSTEM>/<BUGID>   # your folder ONLY — never `git add -A`
git commit -m "eval/<SYSTEM>/<BUGID>: M<N> <one-line outcome>  success=<true|false>"
git push origin main
```

Rules:
- **One milestone per commit.** Prefix every commit `eval/<SYSTEM>/<BUGID>: M<N> ...` and
  end the message with `success=<true|false>` so progress is greppable across the repo.
- **Always `git pull --rebase` before `git push`** — other agents are pushing too; rebase
  avoids divergent histories and lost commits.
- **Stage only your own bug folder** (`git add evaluations/<SYSTEM>/<BUGID>`), never
  `git add -A` or `git add .` — you must not commit another agent's in-progress work or any
  shared file.
- **Never force-push** `main`. If a rebase conflicts on your own folder (rare, since
  folders are disjoint), resolve it on your files only.
- **Keep heavy artifacts out:** `source/`, `logs/`, `repos/` are gitignored — do not
  force-add them. They are reconstructed on resume (§9).

---

## 14. When you finish

1. Ensure every milestone is `DONE` (`success: true`) or, if a step failed, `FAILED`
   (`success: false`) with the rest cascaded to `BLOCKED` (none `IN_PROGRESS`/`PENDING`).
2. Ensure `state.json` and `PROGRESS.md` agree.
3. Ensure `summary.md` exists with the `successes/5` and the discussion paragraph.
4. Leave the folder clean: only documented artifacts, no stray scratch files.
5. Your final message to the operator states: bug id, final status, successes/5.