## Root cause

`TestWebHdfsClientDeadlines` fails only in the four **`*ConnectDeadline`** cases — `testListFilesConnectDeadline` (line 149), `testDelegationTokenConnectDeadline` (line 179), `testChecksumRedirectConnectDeadline` (line 210) and `testCreateRedirectConnectDeadline` (line 242). All of them rely on `fillPendingConnectQueue()` to jam the NameNode HTTP `ServerSocket`'s accept queue so the *next* client connect will time out during the TCP handshake. The `*ReadDeadline` twins (which do not call `fillPendingConnectQueue`) never appear in the failure list — that split is the key clue.

The trap is the mechanism used to "fill" the queue:

```java
// TestWebHdfsClientDeadlines.java:70-71
private static final int PENDING_CONNECT_CLIENTS = 129;
private static final int LISTEN_QUEUE_LENGTH = 1;
...
// TestWebHdfsClientDeadlines.java:110
serverSocket = new ServerSocket(0, LISTEN_QUEUE_LENGTH);
...
// TestWebHdfsClientDeadlines.java:355-362
private void fillPendingConnectQueue() throws IOException {
  for (int i = 0; i < PENDING_CONNECT_CLIENTS; ++i) {
    SocketChannel client = SocketChannel.open();
    client.configureBlocking(false);      // <-- non-blocking
    client.connect(nnHttpAddress);        // <-- kicks off SYN, does NOT wait
    clients.add(client);
  }
}
```

Two things conspire:

1. `client.configureBlocking(false)` followed by `client.connect(...)` **initiates** a TCP handshake and returns immediately. The loop never calls `finishConnect()` and never checks with a `Selector` that the SYN/ACK has actually landed on the server. The 129 iterations return long before the kernel has actually queued 129 established connections at the NameNode socket.
2. The comment at line 350 admits the author knows the kernel can silently raise the backlog above `LISTEN_QUEUE_LENGTH = 1` (Linux uses `min(backlog, net.core.somaxconn)`, and modern kernels — including the 5.15 kernel this run is on — default `somaxconn` to 4096). The "work‑around" is simply to spam more clients, with no verification that the resulting queue is actually full.

Because of (1)+(2) the "queue full" precondition is racy. On the runs where enough of the 129 half‑opened sockets have completed the 3‑way handshake before `fs.listFiles(...)` / `fs.getDelegationToken(...)` fires its own SYN, the real client's connect returns "connect timed out" (test passes). On runs where they have not yet piled up — which is exactly what the log shows for ports 40019 / 38523 / 37959 / 32839 / 35575 / 37089 / 36473 — the accept queue still has room, the real client's TCP handshake succeeds, the bogus server never accepts/reads/replies, and the client's next timer to fire is the read timer (200 ms, `SHORT_SOCKET_TIMEOUT` at line 72), so a `SocketTimeoutException("… Read timed out")` is thrown instead.

## The exact branch that produces the assertion

The failing execution path in every logged failure is:

- The `try` at `TestWebHdfsClientDeadlines.java:151` (or 181/212/245) issues the WebHDFS call — the underlying `HttpURLConnection` has both timers set by `URLConnectionFactory#configure` (lines 82‑86) to 200 ms (or by the `dfs.webhdfs.socket.{connect,read}.timeout` configs at lines 115‑116 for the `Configuration` parameterization; both variants fail because the fault is on the server side, not in how the timer is set).
- Because `fillPendingConnectQueue()` (line 355) did not actually saturate the accept queue, the kernel completes the TCP handshake for the WebHDFS client. `HttpURLConnection.getInputStream()` then blocks on the read timer.
- `SHORT_SOCKET_TIMEOUT = 200` (line 72) elapses → `SocketTimeoutException("<authority>: Read timed out")` propagates.
- Control enters the `catch (SocketTimeoutException e)` at line 154 (or 184 / 215 / 248).
- `GenericTestUtils.assertExceptionContains("<authority>: connect timed out", e)` at lines 155‑156 (or 185‑186 / 216‑217 / 249‑250) inspects `e.getMessage()`, does not find `"connect timed out"`, and raises the exact `AssertionError` that appears in the log:

  `java.lang.AssertionError: Expected to find 'localhost:40019: connect timed out' but got unexpected exception: java.net.SocketTimeoutException: localhost:40019: Read timed out`

## Summary

The failure is not in the WebHDFS client or the timeout wiring — both connect and read timers are correctly plumbed and firing. The defect is in the test's precondition setup: `fillPendingConnectQueue()` at `TestWebHdfsClientDeadlines.java:355-362` uses non‑blocking `SocketChannel.connect()` and a small fixed fan‑out (`PENDING_CONNECT_CLIENTS=129`) to try to overflow a server socket whose kernel‑enforced backlog can be far larger than the requested `LISTEN_QUEUE_LENGTH=1`. The loop returns before the OS has actually queued the connections, so the accept‑queue‑full invariant that the four `*ConnectDeadline` tests depend on holds only probabilistically. When it does not hold, the real client's connect succeeds, the read timer fires first, and the `assertExceptionContains("… connect timed out", e)` assertion in the corresponding test's `catch` block turns the wrong-but-still-a-timeout outcome into the reported `AssertionError`.
