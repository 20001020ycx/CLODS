# HBase-3627 — result

| field | value |
|---|---|
| bug | `HBase-3627` (JIRA [HBASE-3627](https://issues.apache.org/jira/browse/HBASE-3627), "NPE in EventHandler when region already reassigned", Critical; affects 0.90.1, fixed in 0.90.2) |
| system | HBase, branch-0.90 @ `86e9f5f8c9` (pre-fix), fix `79b522db0c` |
| symptom given to the LLM | region servers repeatedly fail to bring regions online; the pasted `NullPointerException` as `logs/symptom.log` prints it (no line number, no marker) |
| symptom log | the **merged** log: 13 673 450 lines / 3.1 GB = 11 945 370 production records + 1 593 535 reproduction records |
| model | `claude-opus-4-7`, effort high, single turn, no follow-ups — the **`ccs anthropic` subscription account** (OAuth, `subscriptionType=max`) straight to **api.anthropic.com**, not a gateway profile; egress iptables-locked to that host only (provenance in `private/m6-harness.log`) |
| **successes (pre-registered primary bar: both sites the fix changed)** | **0 / 5** |
| successes (auxiliary bar: the one site on the reproduced failure path) | **5 / 5** |

## Per-run verdicts

| run | site A — `ZKAssign.transitionNode` 669-673 + missing `existingBytes == null` | site B — `AssignmentManager` TimeoutMonitor `case OPENING:` 1646 + missing `data == null` | primary verdict |
|---|---|---|---|
| 1 | HIT (line + branch, grounded on the ZK reply code `-101` = NONODE) | MISS | FAIL |
| 2 | HIT (line + branch) | MISS | FAIL |
| 3 | HIT (line + branch, + derived the trigger) | MISS | FAIL |
| 4 | HIT (line + branch, **wrote the upstream guard as a patch**) | MISS | FAIL |
| 5 | HIT (line + branch, named it "the true root cause" over the throw site) | MISS | FAIL |

(The batch of record is the 2026-08-18 re-run on the subscription account. An earlier batch on the same account and
configuration, kept verbatim under `private/diagnosis-batch-1/`, produced the same 5×HIT / 0×site-B outcome; it was
superseded only because its harness log — the endpoint provenance — had been cleaned up.)

## Discussion

All five runs isolated the root-causing line **deterministically**: each one grepped 13.7 M lines of
merged production log for the pasted exception, walked the six-frame stack into source it had never
seen under those names, and landed on the unguarded
`byte[] existingBytes = ZKOps.getDataNoWatch(...); RegionStateRecord.fromBytes(existingBytes);` pair
in `RegionStateZK.transitionNode` (= `ZKAssign.transitionNode` 670-673) — the exact two lines the
upstream fix guards — and each stated the exact missing branch (`existingBytes == null → return -1`)
together with the condition that produces the null (`getDataNoWatch`'s `NoNodeException` branch,
i.e. the unassigned znode is gone). Two runs went beyond the symptom and reconstructed the
*trigger* from the log alone — a race in which the master creates or deletes the unassigned znode
underneath a bring-up that is still queued — which `symptom.md` never states. On the part of the
task the experiment is really about, the model did not need a deterministic tool: a fail-stop bug
whose stack trace names the guilty frame is exactly the case where an LLM's parametric reasoning is
enough, even with every failure-path class renamed and every quoted log string rewritten.

The headline **0/5** comes entirely from the second site the same commit fixed: the master's
`TimeoutMonitor`, which dereferences the same `getDataNoWatch` result in its `case OPENING:` branch.
No run mentioned it — and no run could reasonably have: the reproduction never enters that branch
(all 9 700+ regions-in-transition timeouts are `PENDING_OPEN`; zero `OPENING` timeouts and zero
master-side NPEs), so the symptom log carries no evidence for it. This is the same pattern as
Zookeeper-1900: a strict "name every line the fix touched" bar measures how much of the fix the
*symptom* can testify to, not only how well the model reasons — which is why both numbers are
pre-registered in `private/ground_truth.md`, recorded in every `run_N.grade.json`, and reported here.

Two secondary observations for the paper. First, all five runs independently noticed that the NPE is
actually thrown one frame deeper, in the two-argument `Writables.getWritable` overload whose null
guard sits unreachable in the four-argument overload, and offered it as an alternative fix; upstream
chose the caller instead, so this is a defensible-but-different fix rather than an error — the kind
of divergence a line-identity rubric has to adjudicate. Second, the merged production log again
showed its teeth: runs 2 and 5 cite a production-noise record as their evidence (the `-ROOT-` region
`70236052` of the 1.2.7 noise cluster, whose own wording is `because node does not exist (not an
error)`) instead of the reproduction's own `since the node is absent` records, 25 minutes and one
host-section away from the incident. The noise did not move the root-cause verdict here, but it did corrupt
the surrounding story — evidence that "find the root cause inside realistic production noise" is a
distinct capability from "reason about the code", and the one that grounding tools like CLODS are
meant to supply.
