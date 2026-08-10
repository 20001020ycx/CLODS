# prompt.md — agent kickoff (operator → agent)

> This is the prompt an operator hands to a Claude Code agent to evaluate **one** bug.
> Fill in the three placeholders (`<JIRA>`, `<SYSTEM>`, `<BUGID>`) and paste it into a
> fresh Claude Code session running inside the `clods-eval` container (§11). The agent
> then works autonomously to M8 with no further hand-holding.

---

You are evaluating one bug for the CLODS LLM-diagnosis experiment (paper #1972).

**Your only input is the JIRA ticket `<JIRA>`** (system `<SYSTEM>`, bug id `<BUGID>`).
Derive everything else — repo, fix commit, pre-fix commit, symptom, failure path — from
that ticket. Do not ask for additional inputs.

Before doing anything, **read `context/METHODOLOGY.md` in full** — it is your runbook.
Follow its milestones M0→M8 in order. Key rules, repeated here so you cannot miss them:

1. **Workspace.** You own exactly one folder, `evaluations/<SYSTEM>/<BUGID>/`. Create it
   at M0 and write *only* there. Use a per-bug scratch clone at `/work/repos/<SYSTEM>-<BUGID>`.
   Never modify `context/`, `Dockerfile`, `example/`, the repo root, or any other agent's
   folder. Multiple agents share this workspace — do not clobber their work.

2. **Track progress with explicit success.** Keep `PROGRESS.md` and `state.json` in sync;
   every milestone carries `status` + `success` (`true`/`false`/`null`) + `outcome`. If you
   are killed, the next agent resumes from your highest `DONE` milestone, so write state
   atomically (temp-file-then-`mv`).

3. **Commit & push after EVERY milestone.** Right after a milestone is `DONE` (or
   `FAILED`): `git pull --rebase origin main`, then `git add evaluations/<SYSTEM>/<BUGID>`
   (your folder only — never `git add -A`), then
   `git commit -m "eval/<SYSTEM>/<BUGID>: M<N> <outcome>  success=<true|false>"`, then
   `git push origin main`. One milestone per commit.

4. **Append-only coordination log.** Append (with `flock`, never overwrite) a line to
   `evaluations/COORDINATION.log` when you claim the bug, finish each milestone, or hit
   `FAILED`/`BLOCKED` (template in METHODOLOGY.md §13).

5. **Build from source** at the pre-fix commit (not a released binary) so you can rename
   files and rewrite log statements on the failure path at M4. Fix old dependencies as
   needed and save the edits to `private/deps-fix.patch`.

6. **Anonymize** the failure path (rename files + rewrite log literals) so the LLM can't
   map symptoms to known fixes from memory; verify zero original-identifier leakage.

7. **Diagnose 5× independently**, network-locked to `api.anthropic.com` only, with the
   single fixed prompt from METHODOLOGY.md §5/M6. **No follow-up prompts.**

8. **Grade** each run against `private/ground_truth.md` (exact line **and** exact branch;
   no partial credit) and write `summary.md` with `successes/5` and the discussion.

Remember: `source/`, `logs/`, and `repos/` are gitignored (heavy/reproducible) — they are
reconstructed on resume from `anonymization_map.json` + `deps-fix.patch` + `pre_fix_commit`
(§9). Only the lightweight progress files are committed.

Start at M0. Begin.