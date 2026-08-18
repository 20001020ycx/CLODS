(Skipping task tracking — this is a single-shot diagnostic question, no multi-step work to track.)

## Root cause

The failing tests are `TestWebHdfsClientDeadlines#testListFilesConnectDeadline` and `#testDelegationTokenConnectDeadline` (both parametrizations). All three failures share the same shape: they expected a TCP **connect** timeout and instead got an HTTP **read** timeout, which means the WebHDFS client's TCP handshake actually completed and it hung waiting for a response body.

The failure is a race in the test's own "make the connect fail" setup — the client code behaves exactly as designed.

### The intended failure path (what the tests want)

`testListFilesConnectDeadline` (`TestWebHdfsClientDeadlines.java:148-158`) and `testDelegationTokenConnectDeadline` (`:178-188`) both:

1. Call `fillPendingConnectQueue()` (`:355-362`) to saturate a `ServerSocket` that was created with `LISTEN_QUEUE_LENGTH = 1` (`:71`, used at `:110`).
2. Then invoke `fs.listFiles(...)` / `fs.getDelegationToken(...)`, expecting the client's TCP `SYN` to be dropped by the kernel because the accept queue is full → `SocketTimeoutException: <host>:<port>: connect timed out` at `SocksSocketImpl`/`AbstractPlainSocketImpl.connect`.
3. Catch it, and assert (`:155-156`, `:185-186`) that the message contains `<authority>: connect timed out`.

### Why it degrades to "Read timed out" instead

Look at `fillPendingConnectQueue()` closely (`TestWebHdfsClientDeadlines.java:355-362`):

```java
for (int i = 0; i < PENDING_CONNECT_CLIENTS; ++i) {   // 129 iterations (line 70)
  SocketChannel client = SocketChannel.open();
  client.configureBlocking(false);                    // ★ non-blocking
  client.connect(nnHttpAddress);                      // ★ returns immediately
  clients.add(client);
}
```

Two conditions in this loop dictate the bug:

- **Non‑blocking `connect()`**: `SocketChannel.connect()` in non-blocking mode initiates the SYN and returns `false` without waiting for the 3‑way handshake. `finishConnect()` is never called. So on return from `fillPendingConnectQueue`, **there is no guarantee that the kernel's accept queue is full** — 129 handshakes are merely *in flight* in the SYN queue.
- **`nnHttpAddress` is `localhost`** (`:111`). On loopback, RTT is effectively zero; the kernel completes handshakes as fast as it can. But because the *server never calls `accept()`* in the connect‑deadline tests, completed connections pile up in the ServerSocket's accept queue whose depth was requested to be 1 (`new ServerSocket(0, LISTEN_QUEUE_LENGTH)` at `:110`).

The intent is that once the accept queue is full, further SYNs get dropped and the WebHDFS client SYN retries until `SHORT_SOCKET_TIMEOUT = 200 ms` (`:72`) expires. But because of the two conditions above, whether the client's SYN "wins the race" against the 129 background handshakes filling the queue is nondeterministic:

- If the client's SYN arrives while the accept queue still has room → the kernel completes the handshake and enqueues the connection. `HttpURLConnection` proceeds to `getResponseCode()` → the bogus server (which never `accept()`s and never writes) leaves the socket idle → **`Read timed out`** after 200 ms. This is what the log records.
- If it arrives after saturation → SYN is dropped, connect retries and hits 200 ms → **`connect timed out`** (the intended path, hit by the passing runs and by the other "Read"-family tests in the same log).

The other three failed tests in the same suite that expect `Read timed out` (e.g. `testListFilesReadDeadline`) don't call `fillPendingConnectQueue()`, so they cannot regress this way — consistent with the log showing only the "Connect" tests failing.

### The exact branches in the client that produce "Read timed out"

The stack in `symptom.log:27018277-27018368` shows the client took the *successful-connect* branch:

- `WebHdfsFileSystem.listStatus:1699` → `AbstractRunner.run:697` (`doAs`) → `AbstractRunner$1.run:701` → `runWithRetry:835` → `connect:760` → `validateResponse:488`.
- Inside `URLConnectionFactory.openConnection(URL, boolean)` (`URLConnectionFactory.java:179-195`), the `isSpnego` branch at `:181` is **false** for `listFiles`/`getDelegationToken` here (see `if (isSpnego) {...} else {...}` at `:181/:187`). It takes the `else` branch, does a plain `url.openConnection()` and applies the `connConfigurator`.
- The configurator sets `readTimeout = SHORT_SOCKET_TIMEOUT = 200 ms` — either directly from the test's `ConnectionConfigurator` at `TestWebHdfsClientDeadlines.java:80-87` (for `timeoutSource=ConnectionFactory`) or from `URLConnectionFactory.setTimeouts` at `:206-211` fed by `HdfsClientConfigKeys.DFS_WEBHDFS_SOCKET_READ_TIMEOUT_KEY` set at `:113-117` (for `timeoutSource=Configuration`).
- `validateResponse:488` calls `HttpURLConnection.getResponseCode()`, which calls `getInputStream0()` → `HttpClient.parseHTTPHeader` → `SocketInputStream.socketRead0`. The socket is connected but idle → `SocketTimeoutException("<host>:<port>: Read timed out")` at 200 ms.

The message text `"<host>:<port>: Read timed out"` (vs `"<host>:<port>: connect timed out"`) is the JDK's canonical wrapping — it is emitted specifically by the read path, confirming TCP `connect` succeeded and the timeout occurred while waiting for the HTTP response.

### One‑line summary

`fillPendingConnectQueue()` at `TestWebHdfsClientDeadlines.java:355-362` uses *non‑blocking* `SocketChannel.connect()` and never waits for the SYNs to actually saturate the ServerSocket's `LISTEN_QUEUE_LENGTH = 1` accept queue, so when `fs.listFiles`/`fs.getDelegationToken` fires immediately after, the WebHDFS client's TCP connect can slip into the accept queue before it is full; it then hangs in `WebHdfsFileSystem.validateResponse` → `HttpURLConnection.getResponseCode` → `SocketInputStream.read` until the 200 ms `SHORT_SOCKET_TIMEOUT` fires, producing `Read timed out` instead of the asserted `connect timed out`.
