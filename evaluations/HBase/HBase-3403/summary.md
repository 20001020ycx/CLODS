# HBase-3403 — summary

| | |
|---|---|
| **bug** | HBase-3403 ([HBASE-3403](https://issues.apache.org/jira/browse/HBASE-3403), "Region orphaned after failure during split", Blocker, fixed in 0.90.0) |
| **system** | HBase (trunk, January 2011) |
| **fix commit** | `0d31ac5f37a2e8866884bb216a3485eea652a822` (svn trunk@1056884) |
| **pre-fix commit** | `dddee0d50ff77c93a2b39f408bf11f60e397ebf4` |
| **symptom log** | `logs/symptom.log` — 12 002 241 lines / 2.9 GB: 7 361 reproduction records retimed and spread across the shared 11 945 370-record HBase 1.2.7 production log |
| **result** | **5 / 5 PASS** |

## Symptom

A consistency check of the cluster reports a region of `usertable` that is unaccounted for:

```
ERROR: Region hdfs://…/usertable/ac6a4798d6ab5e1826f038e6a5567a16 has a directory on HDFS with no catalog row, and no region server is serving it.
ERROR: Consistency check failed for table usertable
```

(The wording is the M4-anonymized form of the two lines the JIRA reporter posted.) The LLM was
given `source/`, this observable, and the merged production log — nothing about splits, crashes,
or the region server that was lost.

## Root cause (ground truth)

`MetaEditor.offlineParentInMeta` (anonymized `CatalogWriter.offlineSplitParent`) blanks the split
parent's location when it commits the split:

```java
put.add(HConstants.CATALOG_FAMILY, HConstants.SERVER_QUALIFIER,    HConstants.EMPTY_BYTE_ARRAY);
put.add(HConstants.CATALOG_FAMILY, HConstants.STARTCODE_QUALIFIER, HConstants.EMPTY_BYTE_ARRAY);
```

The fix is exactly the deletion of those four lines. With the server column empty,
`MetaReader.getServerUserRegions` (anonymized `CatalogScanner.getRegionsOfServer`, line 578) takes
`pair.getSecond() == null → continue` and drops the parent from the set of regions the crashed
server was carrying; `ServerShutdownHandler.processDeadRegion`'s
`if (hri.isOffline() && hri.isSplit())` branch (line 179) therefore never runs for it, and
`fixupDaughters` — the only code that re-adds a daughter that missed its `.META.` row — is dead.
The daughter is left on HDFS with no catalog row and no server.

## Per-run verdicts

| run | verdict | named the root-causing line (a) | named the deciding branch (b) |
|---|---|---|---|
| 1 | **PASS** | `CatalogWriter.java:80-83`, `EMPTY_BYTE_ARRAY` server/startcode | `CatalogScanner.java:578-579` `continue`; `LostServerHandler.java:179` unreachable |
| 2 | **PASS** | same, called out as what zeroed `info:server` | same, stated as "the failing decision" |
| 3 | **PASS** | same, "wiped to `EMPTY_BYTE_ARRAY`" | same, "recovery filter" + "recovery bypass" |
| 4 | **PASS** | same, "zero-length `info:server` value" | same, plus `recoverSplitChild:209-222` gated on it |
| 5 | **PASS** | same, in a one-sentence root cause | same, "`recoverSplitChildren` … is dead code" |

Grading bar (`private/ground_truth.md` §4, per METHODOLOGY §8): a run passes only if it names
**both** (a) and (b); partial credit is not a pass. All five cleared it, so the secondary tally
("root-causing line only") is also 5/5 and adds nothing.

## Discussion

The LLM isolated this root cause **deterministically**: five independent, single-turn runs, each
starting from nothing but a two-line consistency-checker complaint buried in 12 million lines of
unrelated production logging, all converged on the same two code sites — and on the same causal
direction between them. That is a markedly different outcome from the ZooKeeper and HDFS bugs in
this study, which scored 0/5 under the same merged-production-log protocol, and it is worth being
precise about *why* rather than reading it as a general capability claim.

What made this bug tractable is that its causal chain is **fully witnessed by the log the model was
given**. The reproduction leaves three decisive traces interleaved in the production noise: the
catalog editor announcing that it took the split parent out of service, the master then announcing
that it was "Re-hosting 1 region(s)" for the lost server, and the conspicuous *absence* of any
daughter-repair line. Several runs explicitly used that arithmetic — one region re-hosted where
two were expected — to pin the filter, and one used the missing repair line as evidence the branch
had never been entered. From there the code path is short, synchronous and single-threaded: a
catalog write, a scan filter, an `if`. Nothing depends on timing, on state that was never logged,
or on a value the model would have had to infer. Anonymization held (renamed classes, rewritten
literals, zero leakage of the bug id or the original identifiers), so the runs cannot be explained
by recognition of the ticket; they are genuine static reasoning over the supplied tree.

The contrast with the 0/5 bugs is the useful result. Those failures surfaced as a wrong value or a
hang whose mechanism left **no** discriminating evidence in the log, so the model had to guess
among several plausible mechanisms and anchored on the wrong one. Here the log happened to contain
the counter-evidence. So the honest reading is not "LLMs can statically root-cause distributed
bugs" but rather: an LLM can do so precisely when the observable evidence already determines the
chain — and it cannot tell the two situations apart from the inside. In all five runs the model
was equally confident; on the ZooKeeper bugs it was equally confident and wrong. That is exactly
the gap CLODS targets: a diagnosis grounded in recorded execution rather than in whichever
mechanism reads most plausibly, so that "the log happens to witness the chain" stops being the
thing the answer silently depends on.

## Caveats

- The reproduction is a two-region-server mini cluster in one JVM (see `reproduce.md`), and the
  crash window is simulated by deleting the daughter's `.META.` row — the same simulation the
  upstream fix's own regression test uses. The master's shutdown-recovery path, which is the code
  under test, runs untouched.
- The tree is built against Hadoop `0.20.2` because the 2011 `0.20-append` artifact no longer
  exists anywhere; the bug is entirely inside HBase's `.META.` bookkeeping.
- Run 5 needed two retries for infrastructure reasons only (an account rate limit, then a rotated
  OAuth token). Both non-answers were discarded ungraded; the graded run is a normal single-turn
  answer.
