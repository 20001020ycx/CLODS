# Zookeeper-1434 — milestone tracker

- **System:** Zookeeper
- **JIRA:** ZOOKEEPER-1434 (https://issues.apache.org/jira/browse/ZOOKEEPER-1434)
- **Owner:** agent-run-57ce8ccf
- **Source repo:** https://github.com/apache/zookeeper.git
- **Fix commit:** `7f64942ba8e5ce00948f6e7b23271de0556b668f` (trunk, 2011-05-16, fixVersion 3.4.0)
- **Pre-fix commit:** `59ac9fa78963ca746d21a62a27fde497fd4c4d58`
- **Symptom (short):** the zkCli shell dies with an unhandled `NullPointerException` when the
  node-status command is issued on a path that does not exist.

## Commit derivation (M1)

ZOOKEEPER-1434 ("zkCli crashes with NPE on stat of non-existent path", affects 3.3.5) is
`Resolved / Won't Fix`: the committer declined a 3.3 backport because HBase depended on the
3.3 behaviour **and the same defect was already fixed on trunk/3.4 by ZOOKEEPER-1059**
(identical symptom and identical stack trace). The commit whose diff resolves the reported
defect is therefore `7f64942ba` — it adds the missing `stat == null` guard in
`ZooKeeperMain.processZKCmd`. The 3.3-branch patch attached to ZOOKEEPER-1434 itself
(`private/jira-1434-attached-3.3-patch.diff`) is byte-for-byte the same change, which
confirms the two tickets share one root cause. The pre-fix tree used for the whole
evaluation is `59ac9fa78` (trunk @ 2011-05, 3.4.0-dev), where the `stat` branch calls
`printStat(zk.exists(...))` unguarded.

## Milestones

| ID | Milestone | Status | success | outcome | Note |
|---|---|---|---|---|---|
| M0 | Scaffold & claim | DONE | true | success | folder + trackers created |
| M1 | Identify fix / pre-fix commit | DONE | true | success | fix=7f64942ba (ZOOKEEPER-1059), pre=59ac9fa78 |
| M2 | Build from source at pre-fix | DONE | true | success | `ant jar` on JDK8 in per-bug image |
| M3 | Reproduce the failure | DONE | true | success | real server + 4 real zkCli sessions; uncaught NPE, exit 1 |
| M4 | Anonymize failure path (file/type + log literals) | DONE | true | success | v2: class + all its log statements renamed; log regenerated |
| M5 | Diagnosis inputs & ground truth | DONE | true | success | v2: symptom.md = pasted stack only; GT cross-referenced |
| M6 | LLM diagnosis ×5 (network locked) | DONE | true | success | 5 substantive single-turn answers |
| M7 | Grade runs | DONE | true | success | 5/5 PASS |
| M8 | Summary & finalize | DONE | true | success | summary.md written; result 5/5 |

## Log

- 2026-08-11T20:40:31Z — M0 DONE (success). Created `evaluations/Zookeeper/Zookeeper-1434/`
  with `private/`, `source/`, `logs/`, `diagnosis/`; wrote `PROGRESS.md` + `state.json`;
  claimed the bug in `evaluations/COORDINATION.log`.
- 2026-08-11T20:55:00Z — M1 DONE (success). Fix commit 7f64942ba / pre-fix 59ac9fa78 identified
  from the ticket (via its Won't-Fix rationale pointing at ZOOKEEPER-1059); saved
  `private/fix.diff` and the ticket's own 3.3 patch attachment.

## Build (M2)

- Image: `clods-eval:Zookeeper-Zookeeper-1434` = `clods-eval` + `openjdk-8-jdk` + `ant`
  (`private/Dockerfile.zk1434`). JDK 11/17 cannot compile this tree (`-target` < 7).
- Command: `docker run --rm -v "$PWD:/work" -w /work/repos/Zookeeper-Zookeeper-1434 \
  --entrypoint bash clods-eval:Zookeeper-Zookeeper-1434 -lc 'ant jar'`
- Output: `build/zookeeper-3.4.0.jar`, `build/classes/`, `build/lib/` (slf4j 1.6.1,
  log4j 1.2.15, jline 0.9.94, netty 3.2.2.Final).
- Dependency fixes (`private/deps-fix.patch`, build files only — no source changes):
  1. `build.xml` `ivy.url`: `http://repo2.maven.org/...` → `https://repo1.maven.org/...`
     (host retired; Central refuses plain HTTP).
  2. `ivysettings.xml` `repo.maven.org` → https, and the dead `repo.jboss.org` /
     `download.java.net` mirrors repointed at Central.
  3. `build.xml` `javac.target` `1.5` → `1.8` (javac 8 defaults to `-source 1.8`, which
     is incompatible with `-target 1.5`).

- 2026-08-11T20:50:00Z — M2 DONE (success). `ant jar` BUILD SUCCESSFUL on the pre-fix tree.
- 2026-08-11T20:52:00Z — M3 DONE (success). `reproduce.sh` runs a real standalone server and
  four real zkCli sessions at DEBUG (~900 ops); the status command on a missing znode kills
  the shell with an uncaught NPE (exit 1), frames identical to the JIRA-quoted trace.
  9555-line symptom log (3147 DEBUG), zero injected lines. Write-up in `reproduce.md`.

## Anonymization (M4)

Renames (`private/anonymization_map.json`), both in `ZooKeeperMain.java` only:

| original | anonymized | why |
|---|---|---|
| CLI command `stat` | `meta` | the term that names the case (ticket title, reported session transcript) |
| `printStat` | `printNodeMeta` | the distinctive token of the stack trace the ticket quotes |

Bug-id scrub covers **both** ticket numbers (the report's own and the trunk ticket carrying
the fix). Because the JVM prints `java.class.path` / `user.dir` into the log, the
log-producing build was moved to the neutral path `repos/zookeeper-anonymized` and
`reproduce.sh`'s temp dir renamed to `/tmp/zk-repro-XXXX`.

`private/anonymize.sh` regenerates both gitignored artifacts end-to-end: copy tree →
rename → `ant jar` → re-run `reproduce.sh` (still reproduces, exit 1) → publish
`logs/symptom.log` + `source/` → verify zero leakage. The log is therefore the genuine
output of the renamed binary, never a post-hoc rewrite.

- 2026-08-11T20:55:00Z — M4 DONE (success). Renamed build compiles, still reproduces; 16 curated
  failure-path files in `source/`; leakage checks clean.
- 2026-08-11T20:57:00Z — M5 DONE (success). `symptom.md` (symptom only) and
  `private/ground_truth.md` (root-causing line 726/727 + the missing `stat == null` branch,
  with an explicit per-bug PASS rule) written; leakage greps all zero.

## Diagnosis harness (M6)

```bash
docker run --rm --cap-add=NET_ADMIN --add-host api.anthropic.com:<ip> \
  -v "$PWD/evaluations/Zookeeper/Zookeeper-1434:/bug" \
  -v "<scratch-config-with-oauth-creds>:/root/.claude" \
  -e CLAUDE_CONFIG_DIR=/root/.claude -e IS_SANDBOX=1 -e CLAUDE_PURITY_FLAG=--safe-mode \
  --entrypoint /opt/clods/run_diagnosis.sh clods-eval /bug
```

Harness notes (no change to `context/`, only env knobs the script already exposes):
`--bare` refuses stored OAuth credentials in the container ("Not logged in"), so the
script's documented `CLAUDE_PURITY_FLAG=--safe-mode` path is used (still no CLAUDE.md /
skills / plugins / hooks). `IS_SANDBOX=1` is required because the script passes
`--permission-mode bypassPermissions` and the container must run as root for `iptables`.
`--add-host` pins the API address so the egress allowlist does not depend on DNS working
after the `OUTPUT DROP` policy is installed.

- 2026-08-11T21:20:00Z — M6 DONE (success). 5 network-locked, single-turn diagnoses written.
- 2026-08-11T21:03:00Z — M7 DONE (success). 5/5 PASS; per-run justifications in
  `diagnosis/run_N.grade.json`.
- 2026-08-11T21:05:00Z — M8 DONE (success). `summary.md` written; `state.json.result` =
  5/5 PASS. Bug complete.

## M4 v2 — failure-path anonymization (2026-08-16, revised METHODOLOGY §6(a)-(e))

The methodology was revised after this bug's first pass to require **failure-path file/type
renames** and **failure-path log-statement rewrites**. M4–M8 were reset to `PENDING` and
redone; the v1 artifacts remain in git history (M4 `ef28864`, diagnoses `fc6d587`).

Failure path = the files in the fix diff ∪ the files in the stack trace = **one file**.

| kind | original | anonymized |
|---|---|---|
| file / public type | `ZooKeeperMain.java` / `ZooKeeperMain` | `CliShellMain.java` / `CliShellMain` |
| CLI command | `stat` | `meta` |
| printer method | `printStat` | `printNodeMeta` |
| prompt literal | `[zk: ` | `[client: ` |
| dispatch debug line | `Processing <cmd>` | `Dispatching command: <cmd>` |
| metadata labels | `cZxid`,`ctime`,`mZxid`,`mtime`,`pZxid`,`cversion`,`dataVersion`,`aclVersion`,`ephemeralOwner`,`dataLength`,`numChildren` | `createTxnId`,`createTime`,`modifyTxnId`,`modifyTime`,`childTxnId`,`childVersion`,`contentVersion`,`permVersion`,`sessionOwner`,`contentLength`,`childCount` |
| catch-arm messages | `Node does not exist: `, `Command failed: `, … | `No such node: `, `Command rejected: `, … |
| banner / connect | `Welcome to ZooKeeper!`, `Connecting to `, `JLine support is …` | `Interactive client ready.`, `Contacting server `, `Line editing …` |

Everything off the failure path stays real: package paths, `ZooKeeper`/`ClientCnxn`/
`KeeperException`/`Stat`, the whole server-side log, and ClientCnxn's per-request DEBUG
telemetry. The log is **regenerated** by rebuilding the anonymized tree and re-running
`reproduce.sh` (still reproduces: exit 1, uncaught NPE), so its literals and all six stack
frames match `source/`.

- 2026-08-16T05:15:00Z — M4 REDONE (success) under the revised methodology.

## M5 v2 — symptom.md is now the bare observable (2026-08-16)

The revised methodology forbids stating the trigger, the failing command/path, or any
"what stays correct" narrowing comparison. The v1 `symptom.md` did all three. v2 is one
line of framing plus the stack trace exactly as `logs/symptom.log` prints it — so the model
is no longer told *that* the target path was missing, nor *which* command ran; it has to
find the triggering line in the log itself. `private/ground_truth.md` gained a
real↔anonymized cross-reference table for grading.

- 2026-08-16T05:17:00Z — M5 REDONE (success). Verification gate passed.
