## Root cause

The failing tests are the **connect-deadline** cases:

- `testListFilesConnectDeadline[timeoutSource=ConnectionFactory]` and `[timeoutSource=Configuration]`
- `testDelegationTokenConnectDeadline[timeoutSource=Configuration]`

(All in `source/hadoop-hdfs/src/test/java/org/apache/hadoop/hdfs/web/TestWebHdfsClientDeadlines.java`.)

Each of these expects the client's HTTP request to fail with **`"<authority>: connect timed out"`**, but the run instead gets **`"<authority>: Read timed out"`**. The stack trace in `logs/symptom.log:27018337-27018369` confirms the read timeout comes from `SocketInputStream.read()` under `HttpClient.parseHTTPHeader → HttpURLConnection.getResponseCode` invoked by `WebHdfsFileSystem.validateResponse:488` — i.e. the TCP handshake to the test server **did** succeed; only the wait for the response body timed out.

### Why it went down the wrong branch

The tests assume that saturating the TCP accept queue will cause the *next* client SYN to be dropped, producing a connect‑timeout. The saturation code is:

- `TestWebHdfsClientDeadlines.java:70` — `PENDING_CONNECT_CLIENTS = 129`
- `TestWebHdfsClientDeadlines.java:71` — `LISTEN_QUEUE_LENGTH = 1`
- `TestWebHdfsClientDeadlines.java:110` — `serverSocket = new ServerSocket(0, LISTEN_QUEUE_LENGTH);`
- `TestWebHdfsClientDeadlines.java:355-362` — `fillPendingConnectQueue()` fires 129 non‑blocking `SocketChannel.connect(nnHttpAddress)` calls, expecting some to fill the backlog.

That assumption is invalid on the environment used here. Linux silently clamps the listen backlog up to `net.core.somaxconn`, which on modern kernels is far larger than 129 (default 4096+). So even with `backlog=1` requested and 129 pending clients, the server's accept queue never fills. The test's own server thread never calls `serverSocket.accept()` in these tests (unlike `startOneShotRedirectResponder`), so all 129 pending connections and the real client's connection all complete in the kernel and sit unaccepted.

Consequently, for the WebHDFS client:

1. `URLConnectionFactory.openConnection` performs a TCP connect that succeeds immediately on loopback → **no `SocketTimeoutException("connect timed out")` is thrown**.
2. The HTTP GET request is written and the client waits on `parseHTTPHeader` for a response.
3. Nothing is ever read from the server socket (no `accept()` was called), so after `SHORT_SOCKET_TIMEOUT = 200 ms` (`TestWebHdfsClientDeadlines.java:72`) the JDK throws `SocketTimeoutException("<host>:<port>: Read timed out")`.

### The exact assertion branches that fire

For each failing test, control enters the `catch (SocketTimeoutException e)` block that was written to expect a *connect* timeout:

- `testListFilesConnectDeadline` — `TestWebHdfsClientDeadlines.java:152` (call) → `:154` (catch) → assertion at `:155-156`:
  ```java
  GenericTestUtils.assertExceptionContains(fs.getUri().getAuthority()
      + ": connect timed out", e);
  ```
  `e.getMessage()` is `"localhost:40019: Read timed out"`, which does not contain the expected substring, so `assertExceptionContains` throws `AssertionError` (log line 27018277, stack rooted at `TestWebHdfsClientDeadlines.testListFilesConnectDeadline(TestWebHdfsClientDeadlines.java:155)`).

- `testDelegationTokenConnectDeadline` — `:182` (call `fs.getDelegationToken("renewer")`) → `:184` (catch) → assertion at `:185-186` (log line 27018370, rooted at `:185`).

- Same for the second parameterization of `testListFilesConnectDeadline` (log line 27018450, `:155`).

### Client‑side path that produces the actual "Read timed out"

The stack in the log lines up with:

- `WebHdfsFileSystem.validateResponse:488` calls `conn.getResponseCode()` (`HttpURLConnection.java:527`).
- That drives `HttpURLConnection.getInputStream0 → HttpClient.parseHTTP → parseHTTPHeader → BufferedInputStream.fill → SocketInputStream.read`, which blocks on the socket for `SHORT_SOCKET_TIMEOUT` (200 ms, `TestWebHdfsClientDeadlines.java:72`, applied either via the `URLConnectionFactory` at `:80-87` or via the two `HdfsClientConfigKeys.DFS_WEBHDFS_SOCKET_{READ,CONNECT}_TIMEOUT_KEY` settings at `:114-116`, per `timeoutSource`).

Because the server side (`fillPendingConnectQueue` at `:355-362`, plus the fact that no `accept()` is done in these tests) does not drop the client's SYN, the read‑side timeout fires instead of the connect‑side one, and the connect‑deadline assertions at lines 155-156 and 185-186 fail exactly as the symptom describes.

### One‑line summary

Root cause: `TestWebHdfsClientDeadlines.fillPendingConnectQueue()` (lines 355‑362) with `LISTEN_QUEUE_LENGTH = 1` (line 71) and `PENDING_CONNECT_CLIENTS = 129` (line 70) fails to overflow the test server's TCP accept queue on this kernel (the requested backlog is silently promoted to `net.core.somaxconn`), so the WebHDFS client's connect on the loopback socket succeeds; it then blocks in `WebHdfsFileSystem.validateResponse:488 → HttpURLConnection.getResponseCode` waiting for a response that never comes (no `accept()` in the test's server thread for the connect‑deadline tests), so the 200 ms read timeout (line 72) trips first, producing `SocketTimeoutException: <authority>: Read timed out` — which then causes `assertExceptionContains(...": connect timed out", e)` at `TestWebHdfsClientDeadlines.java:155-156` (and `:185-186`) to fail with the observed `AssertionError`.
