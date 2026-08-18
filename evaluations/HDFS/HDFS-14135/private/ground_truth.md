# HDFS-14135 — ground truth (answer key; never shown to the diagnosis LLM)

Derived from `private/fix.diff` (trunk fix commit
`6b8107ad97251267253fa045ba03c4749f95f530`, pre-fix parent
`b7fba78fb63a0971835db87292822fd8cd4aa7ad`). Anonymized names are as they appear in
`source/` — see `private/anonymization_map.json`.

All of the fix is in one file:

| | real (pre-fix tree) | anonymized (`source/`) |
|---|---|---|
| file | `hadoop-hdfs-project/hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/web/TestWebHdfsTimeouts.java` | `hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/web/TestWebHdfsClientDeadlines.java` |
| helper | `consumeConnectionBacklog()` | `fillPendingConnectQueue()` |
| constant | `CLIENTS_TO_CONSUME_BACKLOG = 129` | `PENDING_CONNECT_CLIENTS = 129` |
| constant | `CONNECTION_BACKLOG = 1` | `LISTEN_QUEUE_LENGTH = 1` |
| checks | `testConnectTimeout`, `testAuthUrlConnectTimeout`, `testRedirectConnectTimeout`, `testTwoStepWriteConnectTimeout` | `testListFilesConnectDeadline`, `testDelegationTokenConnectDeadline`, `testChecksumRedirectConnectDeadline`, `testCreateRedirectConnectDeadline` |

---

## 1. The root-causing line(s) — what the fix changed

**Pre-fix lines 355–362** (`consumeConnectionBacklog()` / anonymized
`fillPendingConnectQueue()`), the whole body:

```java
private void consumeConnectionBacklog() throws IOException {
  for (int i = 0; i < CLIENTS_TO_CONSUME_BACKLOG; ++i) {   // 356  fixed count, not a condition
    SocketChannel client = SocketChannel.open();           // 357
    client.configureBlocking(false);                       // 358  <-- non-blocking
    client.connect(nnHttpAddress);                         // 359  <-- only *initiates* the handshake
    clients.add(client);                                   // 360
  }
}                                                          // 362  returns with the queue possibly empty
```

The method's contract is "the listen queue of `serverSocket` is now full". It never
establishes that. Because every channel is put in **non-blocking** mode at line 358,
`connect()` at line 359 returns as soon as the SYN is queued, so when the loop's fixed bound
`i < CLIENTS_TO_CONSUME_BACKLOG` (line 356) is exhausted and the method returns, none of the
129 handshakes need have completed and the kernel accept queue of
`new ServerSocket(0, CONNECTION_BACKLOG)` (line 110, backlog 1) can still have room.

**The fix** appends to this same method a wait that turns the assumption into a checked
condition — poll every 100 ms for up to 10 s, and treat the queue as full only when a fresh
**blocking** probe connect with a 100 ms deadline actually times out:

```java
try {
  GenericTestUtils.waitFor(() -> {
    try (SocketChannel c = SocketChannel.open()) {
      c.socket().connect(nnHttpAddress, 100);
    } catch (SocketTimeoutException e) {
      return true;                       // <-- the real "backlog is full" predicate
    } catch (IOException e) {
      LOG.debug("unexpected exception: " + e);
    }
    return false;
  }, 100, 10000);
} catch (TimeoutException | InterruptedException e) {
  failedToConsumeBacklog = true;
  assumeBacklogConsumed();
}
```

plus the supporting `private volatile boolean failedToConsumeBacklog` field (reset in
`setUp()`) and

```java
private void assumeBacklogConsumed() {
  if (failedToConsumeBacklog) {
    throw new AssumptionViolatedException("failed to fill up connection backlog.");
  }
}
```

and calls to `assumeBacklogConsumed()` in the `catch (SocketTimeoutException e)` blocks of
`testRedirectConnectTimeout` (pre-fix line 216, before `assertExceptionContains`) and
`testTwoStepWriteConnectTimeout` (pre-fix line 249), so a run that could not saturate the
queue is skipped instead of reported as a failure.

## 2. The exact branch/condition that dictates the failure path

Two conditions, both required:

1. **The loop bound is a count, not the state it stands for** —
   `for (int i = 0; i < CLIENTS_TO_CONSUME_BACKLOG; ++i)` (line 356) is the *only* condition
   guarding the return from `consumeConnectionBacklog()`. Combined with
   `client.configureBlocking(false)` (line 358), the predicate that actually matters — "a new
   connect to `nnHttpAddress` no longer completes" — is never evaluated before the method
   returns. Whenever the handshakes are still in flight at that moment, the accept queue of
   the backlog-1 `ServerSocket` still has room and the next connect **succeeds**.

2. **The connect-deadline checks then take the wrong arm of their `catch`** — in
   `testConnectTimeout` (149), `testAuthUrlConnectTimeout` (179),
   `testRedirectConnectTimeout` (210) and `testTwoStepWriteConnectTimeout` (242) the body is

   ```java
   consumeConnectionBacklog();            // (or the same call inside the redirect responder thread)
   try {
     <webhdfs operation>;
     fail("expected timeout");            // 153 / 183 / 214 / 247
   } catch (SocketTimeoutException e) {
     GenericTestUtils.assertExceptionContains(
         fs.getUri().getAuthority() + ": connect timed out", e);   // 155 / 185 / 216 / 249
   }
   ```

   With the queue not saturated the operation connects, so the `SocketTimeoutException` that
   arrives is the **read** deadline (`": Read timed out"`, thrown from
   `WebHdfsFileSystem.validateResponse` → `HttpURLConnection.getResponseCode`) rather than the
   connect deadline, and `assertExceptionContains(... ": connect timed out", e)` fails — the
   observable. (If no exception arrives at all, the `fail("expected timeout")` arm fires
   instead; both arms are the same defect.)

   `testRedirectConnectTimeout` / `testTwoStepWriteConnectTimeout` are additionally racy
   because their `consumeConnectionBacklog()` runs on the redirect responder thread
   (`startSingleTemporaryRedirectResponseThread`, line 313), concurrently with the main
   thread's second connect — which is why the fix adds `assumeBacklogConsumed()` to exactly
   those two.

The read-deadline checks (`testReadTimeout`, `testAuthUrlReadTimeout`,
`testRedirectReadTimeout`, `testTwoStepWriteReadTimeout`) never call
`consumeConnectionBacklog()` and are unaffected — a run in which only connect-deadline checks
fail is the signature of this defect.

---

## 3. PASS criteria (METHODOLOGY §8)

A run PASSes **only** if it names both:

1. **the line(s)** — the body of `consumeConnectionBacklog()` / `fillPendingConnectQueue()`
   (the non-blocking `connect()` loop that returns without confirming the accept queue is
   full); naming the helper and the missing wait is enough, line numbers may differ, and
2. **the branch/condition** — that the loop's fixed `i < CLIENTS_TO_CONSUME_BACKLOG` count is
   used in place of the real predicate ("a further connect no longer completes"), so with the
   handshakes still in flight the connection **is accepted**, and the connect-deadline check's
   `catch (SocketTimeoutException)` / `assertExceptionContains(... ": connect timed out")` then
   sees a *read* deadline (or no exception → `fail("expected timeout")`).

Naming only the client (`WebHdfsFileSystem`, `URLConnectionFactory`), only the socket
timeouts, only "a race", or only "the OS may enlarge the backlog" without locating the
missing saturation check in the helper = **FAIL**. Right helper but no statement of the
wrong condition = **FAIL**. Partial credit is not a pass.
