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
| M4 | Anonymize + re-confirm | DONE | true | success | 2 renames; renamed build rebuilt & re-reproduced |
| M5 | Diagnosis inputs & ground truth | PENDING | null | pending | |
| M6 | LLM diagnosis ×5 (network locked) | PENDING | null | pending | |
| M7 | Grade runs | PENDING | null | pending | |
| M8 | Summary & finalize | PENDING | null | pending | |

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
