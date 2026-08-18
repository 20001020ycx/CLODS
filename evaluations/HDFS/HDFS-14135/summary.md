# Summary — HDFS-14135

## Result
**Successes: 5 / 5**

| Run | Verdict | Why |
|-----|---------|-----|
| 1 | PASS | Names `fillPendingConnectQueue()` (pre-fix `consumeConnectionBacklog`, lines 355–362) and both conditions: the non-blocking `connect()` loop returns before the handshakes saturate the backlog-1 accept queue, so the check's `catch (SocketTimeoutException)` → `assertExceptionContains("…: connect timed out")` sees a read deadline. Also derives the discriminator (only the checks that call the helper fail). |
| 2 | PASS | Calls the helper body "the defect", pinpoints `configureBlocking(false)` + `connect()` at 358–359, states the precondition that fails to hold and the exact assertion branch at 155–156 / 185–186. |
| 3 | PASS | Right lines (355–362) and right branch (155–156 / 185–186), and states the count-based fill never establishes saturation. **Caveat:** its kernel-level story is wrong — it claims Linux "clamps the backlog up to `somaxconn`" and that all 129 handshakes complete, the opposite of the actual race. |
| 4 | PASS | Right lines and a branch table including the failing assertion; same speculative-kernel caveat as run 3. |
| 5 | PASS | The most precise: the loop "returns long before the kernel has actually queued the connections", performs no verification, and the "queue full precondition is racy" — plus the exact assertion branch in each failing check. |

## System / bug
- **System:** Apache Hadoop **HDFS**, trunk at `b7fba78fb63` (3.3.0-SNAPSHOT, 2019-07-25).
- Real bug: HDFS-14135, fixed by `6b8107ad972`. Only the JIRA id was scrubbed; the
  case-identifying test file/type `TestWebHdfsTimeouts` was renamed to
  `TestWebHdfsClientDeadlines`, its helper `consumeConnectionBacklog` to
  `fillPendingConnectQueue`, its constants and check names likewise, and the failure-path log
  and failure-message literals were rewritten (`private/anonymization_map.json`).

## Symptom given to the LLM
The pasted `AssertionError` from the log — a WebHDFS request that was expected to fail while
*connecting* instead reports `…: Read timed out` — plus a pointer to `logs/symptom.log`, the
7.4 GB merged production log (26 323 996 production + 15 186 reproduction records). No
trigger, mechanism, component or branch was stated.

## Ground truth
`consumeConnectionBacklog()` (pre-fix lines 355–362) promises "the listen queue is now full"
but never establishes it: every channel is put in **non-blocking** mode, so `connect()` only
initiates the handshake, and the loop's sole exit condition is the fixed count
`i < CLIENTS_TO_CONSUME_BACKLOG` (129). When it returns with handshakes still in flight, the
accept queue of `new ServerSocket(0, CONNECTION_BACKLOG = 1)` can still have room, the client
connects, and the connect-deadline checks take the wrong arm of
`catch (SocketTimeoutException e)` → `assertExceptionContains(authority + ": connect timed out", e)`,
which sees `": Read timed out"` instead. The fix turns the assumption into a checked
condition — poll up to 10 s until a fresh blocking probe connect actually times out — and
skips the check (`AssumptionViolatedException`) when saturation cannot be reached.

## What was measured about the kernel (added after grading)
Replaying the helper's trick in isolation on the reproduction host and reading the listening
socket's accept-queue depth from `/proc/net/tcp{,6}`: `new ServerSocket(0, 1)` gives a queue of
**2** (Linux applies `min(backlog, somaxconn)` — `somaxconn` is a cap, not a floor), the queue
reads **full immediately** after the 129 non-blocking connects and stays full from 1 ms to 5 s,
and an isolated client connect correctly timed out in **50/50** attempts with and without the
2 ms delay. Two consequences: (a) the "Linux clamps the backlog *up* to `somaxconn`, so it never
fills" story in runs 3 and 4 is **false on this host**; (b) the minimal harness does not
reproduce the client slipping through, so the fine-grained kernel-level trigger inside the full
suite is **not established by measurement** — the code-level defect (the helper asserts an
invariant it never checks) is what is established, and is what upstream changed.

## Grading
Scored on **root-cause identification only** — the exact root-causing line(s) **and** the exact
branch conditions. Whatever repair a run proposed is not part of the verdict. All five located
the root cause from the anonymized source plus the merged production log alone, with no
follow-up prompts. Runs 3 and 4 attached an incorrect kernel-level rationale (`somaxconn`
clamping) to an otherwise correct code-level diagnosis; since the root-causing line and the
deciding branch are right in both, they score PASS, with the caveat recorded in their grade
JSONs. Run 3 is the weakest of the five: its account of *why* the accept queue is not full
contradicts the actual mechanism.

## Discussion
This bug is the *easy* end of the spectrum for a static reasoner, and the result shows it:
5/5, deterministically. Three properties made it tractable. First, the observable is
self-describing — the runner's own `AssertionError` states both what was expected and what
arrived, so the contradiction ("the connection was established when it should not have been")
is handed over in one line. Second, the failure path is short and entirely inside one file the
model was given, with the log's stack trace walking it. Third, there is a clean
discriminator in the log: only the checks that call the helper fail, and their read-deadline
twins pass, which most runs used explicitly to localize the helper. Contrast HDFS-11896 in
this same workspace, where the observable was a wrong metric value with no stack, the causal
chain crossed several classes, and all five runs settled on a plausible-but-secondary fix
(0/5). Together the two results sketch the boundary: when the symptom text already encodes the
violated invariant and the chain is one hop, an LLM isolates the exact line and branch reliably;
when the symptom is a bare wrong value and the chain must be reconstructed across components,
it does not — which is where a deterministic, field-level observation tool such as CLODS has to
supply the grounding rather than the model's priors. A further caution visible even in this
5/5 case: runs 3 and 4 invented a confident but incorrect kernel-level mechanism on top of the
right answer, so agreement between runs is not by itself evidence that the reasoning underneath
is sound.
