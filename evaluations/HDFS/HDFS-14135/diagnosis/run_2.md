## Root cause

The failure is in `TestWebHdfsClientDeadlines`, in the two `*ConnectDeadline` tests (`testListFilesConnectDeadline` at line 148 and `testDelegationTokenConnectDeadline` at line 178). The test infrastructure that is supposed to force a **connect** timeout does not actually saturate the server's TCP accept queue, so the WebHDFS client's connection is established normally, and a **read** timeout fires instead.

### The exact failure path (branches taken)

1. `TestWebHdfsClientDeadlines.setUp` (line 108) builds a `ServerSocket` with backlog `LISTEN_QUEUE_LENGTH = 1` on an ephemeral port (line 110–112) but **never** calls `serverSocket.accept()` anywhere in the "connect deadline" scenarios (no `startOneShotRedirectResponder` is invoked, and `serverThread` stays `null`, line 125).

2. `testListFilesConnectDeadline` (line 149) calls `fillPendingConnectQueue()` and then `fs.listFiles(new Path("/"), false)` at line 152. The intended branch is `catch (SocketTimeoutException e)` → `assertExceptionContains("… : connect timed out", e)` at line 155–156.

3. `fillPendingConnectQueue()` at line 355–362 tries to consume the OS accept backlog:
   ```java
   for (int i = 0; i < PENDING_CONNECT_CLIENTS; ++i) {          // 129 iterations
     SocketChannel client = SocketChannel.open();
     client.configureBlocking(false);   // <-- non-blocking
     client.connect(nnHttpAddress);     // <-- returns immediately
     clients.add(client);
   }
   ```
   This is the defect. Because `configureBlocking(false)` is set on line 358 before `connect()` on line 359, `SocketChannel.connect` only initiates the SYN and returns immediately without waiting for the three-way handshake to complete. `finishConnect()` is never called on any of the 129 sockets, so from the client side the connections are left half-open.

   On this kernel the resulting behavior is that the accept queue is **not** actually filled synchronously by these 129 calls: some of the pending non-blocking connects have not yet had their handshake completed and moved into the LISTEN socket's accept queue by the time the WebHDFS client makes its own connect. The evidence is in the log at line 27018277 / 27018371 / 27018451: the exception is `SocketTimeoutException: localhost:<port>: Read timed out`, i.e. the TCP handshake succeeded (otherwise the JVM would have thrown `connect timed out`) and the socket then blocked in `SocketInputStream.socketRead0` for 200 ms (the stack in the log shows exactly `SocketInputStream.read → BufferedInputStream.fill → HttpURLConnection.getInputStream…`).

4. Because the connect succeeded, the WebHDFS client posts its GET and waits for the bogus `ServerSocket` (which is never `accept()`-ed by anyone) to reply. After `SHORT_SOCKET_TIMEOUT = 200 ms` (line 72, applied at lines 83–84 for `ConnectionFactory`, or lines 114–116 for `Configuration`), `SocketInputStream.read` throws `SocketTimeoutException("Read timed out")`. `URLConnectionFactory`/`NetUtils.wrapException` prepends the authority, producing `localhost:40019: Read timed out`.

5. Control lands in the `catch (SocketTimeoutException e)` block (line 154 for `listFiles`, line 184 for `getDelegationToken`). The assertion at line 155–156 (and 185–186) requires the message to contain:
   ```
   fs.getUri().getAuthority() + ": connect timed out"
   ```
   The actual message contains `": Read timed out"`, so `GenericTestUtils.assertExceptionContains` raises:
   ```
   java.lang.AssertionError: Expected to find 'localhost:40019: connect timed out'
     but got unexpected exception: java.net.SocketTimeoutException: localhost:40019: Read timed out
   ```

### The specific lines and conditions

- **The wrong-branch assertion that surfaces the failure**: `TestWebHdfsClientDeadlines.java:155–156` (and mirrored at `:185–186`) — reachable only because the caught `SocketTimeoutException`'s message did not contain `"connect timed out"`.
- **The precondition that fails to hold**: `fillPendingConnectQueue()` at `TestWebHdfsClientDeadlines.java:355–362`. The two-line combination of `client.configureBlocking(false);` (line 358) followed by `client.connect(nnHttpAddress);` (line 359) with no `finishConnect()` means the loop does not reliably fill the OS's accept backlog for a `ServerSocket(0, LISTEN_QUEUE_LENGTH=1)` (line 110, using constant at line 71). Because the backlog is not full when `fs.listFiles(...)`/`fs.getDelegationToken(...)` runs (lines 152 and 182), the client's blocking `connect` completes successfully instead of timing out.
- **The read that then times out**: the 200 ms read timeout comes from either the `ConnectionConfigurator` at lines 83–84 (parameter `TimeoutSource.ConnectionFactory`, wired at line 121) or the config keys set at lines 114–116 (parameter `TimeoutSource.Configuration`); both parameterizations of the test fail identically, which the log confirms (failures #1 and #3 for `testListFilesConnectDeadline[…ConnectionFactory]` and `[…Configuration]`, plus #2 for `testDelegationTokenConnectDeadline[…Configuration]`).

In short: the test's `fillPendingConnectQueue` helper (line 355), using non-blocking `SocketChannel` connects that are never finished, does not actually saturate the listen backlog of the `ServerSocket` created in `setUp` (line 110). The WebHDFS client therefore completes the TCP handshake and hits the 200 ms **read** timeout, which fails the `assertExceptionContains("... connect timed out", e)` check at lines 155/185.
