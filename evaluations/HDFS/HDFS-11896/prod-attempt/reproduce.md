# Reproduction — HDFS-11896 (production-log attempt)

This is a **separate attempt** from the top-level minicluster reproduction. Here the symptom
log is a **real production log set**, not something we generated.

## Source
`/homes/ycx/logs/hdfs-11896/hdfs_production_logs_50_8_28/` — a real **50-DataNode + 1-NameNode**
HDFS cluster (Hadoop **2.7.4-SNAPSHOT**, matching `source/`), ~1.5 GB total. The bug is a
NameNode-side accounting bug, so the relevant file is the NameNode log
`hadoop-master__logs__hadoop.log` (30 MB, 152,644 lines, DEBUG level). The 50 DataNode logs are
DN-side block traffic and contain neither the metric nor the NN failure-path events, so they
are not used.

## The bug is genuinely present in this log
- `172.25.0.38` registers at 23:19:02 (`registerDatanode`, uuid `b822daed…`).
- Dies at **23:27:34** — `BLOCK* removeDeadDatanode: lost heartbeat from 172.25.0.38:50010`
  (anonymized `logs/symptom.log:107831`).
- **Re-registers at 23:28:40** — `registerDatanode: from DatanodeRegistration(172.25.0.38…)`
  same uuid (`logs/symptom.log:114118`).
- The `CapacityUsedOther` (= `nonDfsUsed`) metric sample **jumps across that event**:
  `109,853,041,161,909` at 23:26:30 (`:89776`) → `112,355,996,402,777` at 23:29:16 (`:121401`)
  — **+~2.5 TB**, that node's other-used contribution double-counted. That is HDFS-11896.

## Anonymization (same technique)
`private/anonymize_prod.sh` applies the identical transform as the top-level
`private/anonymize.sh`: scrub the JIRA id (none present) and rename the distinctive metric
`nonDfs → other` (`CapacityUsedNonDFS → CapacityUsedOther`, `getCapacityUsedNonDFS →
getCapacityUsedOther`, "non DFS" → "other"). Everything else — class names, IPs (`172.25.0.x`),
storage UUIDs, cluster id — is kept, per the minimal policy. Verified: 0 bug-id, 0 `nonDfs` in
`logs/symptom.log`.

## Symptom given to the LLM (`symptom.md`)
Per the bare-observable M5 rule and the operator's instruction ("verbally describe it like
non-dfs value is abnormal"): *the `CapacityUsedOther` metric reads an abnormally high value,
inflated beyond the actual non-service disk usage; the samples are in `logs/symptom.log`.* No
trigger, mechanism, or narrowing.

## Important confound (documented for honesty)
This is a **Docker-compose cluster: ~50 DataNode containers on one physical host**. Each DN's
`df`-derived non-DFS figure reflects the *same* host filesystem, so the NameNode's cluster
`CapacityUsedOther` is already inflated ~N× (≈110 TB) as a **benign artifact of the test
setup** — independent of HDFS-11896. HDFS-11896 is the *additional* ~2.5 TB step when
`172.25.0.38` re-registers. The bare "abnormally high" symptom therefore points primarily at
the benign baseline, not at the bug's smaller signal.
