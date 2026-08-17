# Diagnosis batch — 2026-08-17 (model gateway)

Re-run of M6 on the merged production log after `context/run_diagnosis.sh` was switched to
the **yscope-anthropic-paper-validation** gateway. The previous batch (in `../`, dated
2026-08-16) is untouched; the aborted OAuth attempt from earlier today is preserved in
`../2026-08-17-oauth-superseded/`.

## Configuration

| | |
|---|---|
| endpoint | `https://llm-gateway.yscope.io` (bearer token via `--env-file`, no OAuth) |
| egress lock | iptables DROP + ACCEPT `llm-gateway.yscope.io:443` only |
| model / effort | `claude-opus-4-7` / `high` |
| purity | `--bare --no-session-persistence --exclude-dynamic-system-prompt-sections`; `Bash,Write,Edit,WebFetch,WebSearch,Task,NotebookEdit` denied |
| inputs staged | `source/` (297 files) + `logs/symptom.log` (1.5 GB, 8 072 681 lines) + `symptom.md` |
| `private/` | not mounted into the container at all (`ls /bug/private` → No such file) |
| runtime | 12–25 min per run |

Run with `private/run_diagnosis.prodlog.sh`: a copy of the tracked
`context/run_diagnosis.sh` differing by **exactly one line** — the M6 prompt, using the
production-log wording that METHODOLOGY §5/M6 specifies and the tracked script has not yet
adopted. The previous production-log batch used that same prompt, so the two are comparable.
`IS_SANDBOX=1` is also passed (the script uses `--permission-mode bypassPermissions` and the
container must be root for iptables; without it every run dies with
"--dangerously-skip-permissions cannot be used with root/sudo privileges").

## Result: 0/4 PASS (run 5 blocked by quota)

| run | verdict | conclusion reached |
|---|---|---|
| 1 | FAIL | head-of-line blocking in `StagedRequestProcessor` |
| 2 | FAIL | head-of-line blocking of pings behind a pending write |
| 3 | FAIL | single in-flight write stalls the whole pipeline |
| 4 | FAIL | single-threaded commit pipeline saturates under write load |
| 5 | — | not produced: gateway returned `429 Daily quota exceeded for model group "claude-opus-4-7"`, resets 2026-08-18T08:00-04:00 |

**None of the four found the failure.** `createExt` appears 0 times and
`NullPointerException` 0 times in all four answers — they never located the one NPE in
8 072 681 lines. All four instead diagnosed a plausible-but-wrong stall: a write sets
`nextPending`, the `!isWaitingForCommit()` guard blocks the drain loop, pings go unserviced
past the 6666 ms client read timeout. Real code behaviour, but not what happened — the
processor was *halted* by `cleanup()` after the NPE, not waiting for a commit.

## Comparison with the 2026-08-16 batch (same inputs, same prompt, OAuth endpoint)

| | found the NPE | named `needCommit` case | named both sites (PASS) |
|---|---|---|---|
| 2026-08-16 (api.anthropic.com) | 3/5 | 3/5 | 0/5 |
| 2026-08-17 (gateway) | 0/4 | 0/4 | 0/4 |

Both settings give 0 PASS, so the headline is unchanged. The *quality* difference is worth
investigating rather than reporting as a model difference: the gateway profile sets
`CLAUDE_CODE_DISABLE_1M_CONTEXT=true`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000` and
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=89`, whereas the OAuth runs had the larger context window.
On a task whose whole difficulty is grepping an 8 M-line log, a smaller window plus
auto-compaction is a plausible cause of losing the thread before reaching the NPE — a
confound between the two batches, not necessarily a property of the subject.

The ×42 time-dilation artifact from the M3/M4 merge (see `../../reproduce.md`) also pushes
answers toward stall theories; `private/merge_logs.py --span-mode natural` removes it.
