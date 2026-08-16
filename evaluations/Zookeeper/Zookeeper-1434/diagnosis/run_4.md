## Root Cause

The shell crashed because the `meta` command handler does not guard against a non-existent znode. The user typed `meta /app/workers/w4242` at line 9546 of the log — a path that doesn't exist. The server responded with error `-101` (NoNodeException) at line 9548, and the CLI then dereferenced a null `Stat`.

### The failure path

**1. Dispatch — `CliShellMain.java:724-727`**
```java
} else if (cmd.equals("meta") && args.length >= 2) {
    path = args[1];
    stat = zk.exists(path, watch);   // returns null when the node is absent
    printNodeMeta(stat);              // called unconditionally
}
```
The controlling branch is `cmd.equals("meta") && args.length >= 2`, which is true for `meta /app/workers/w4242`. Per the ZooKeeper API contract, `ZooKeeper.exists(path, watch)` returns `null` (rather than throwing) when the node does not exist — exactly the server reply seen in the log (`replyHeader … ,-101`). The code does **not** null-check `stat` before calling `printNodeMeta`, and there is no `try/catch` around it either (unlike `listquota` at lines 743-745 which catches `NoNodeException`).

**2. NPE site — `CliShellMain.java:131-132`**
```java
private static void printNodeMeta(Stat stat) {
    System.err.println("createTxnId = 0x" + Long.toHexString(stat.getCzxid()));
```
With `stat == null`, `stat.getCzxid()` throws `NullPointerException` on line 132 — the first field access.

**3. Propagation**
`printNodeMeta` and `processZKCmd` (line 543 onward) do not catch the NPE. `processCmd` (line 583) re-throws it into `executeLine` (355), `run` (313), and finally `main` (272), which is declared `throws KeeperException, IOException, InterruptedException` — none of which catch `RuntimeException`. The JVM prints the stack trace and exits with code 1.

### The exact logical conditions that dictate the failure

1. The parsed command is `"meta"` and `args.length >= 2` → dispatcher takes the branch at line 724.
2. The path argument (`/app/workers/w4242`) does not exist in the ZooKeeper tree → `zk.exists(...)` returns `null` at line 726 (server rc = -101, visible on log line 9548).
3. The branch has no `if (stat != null)` guard and no surrounding `try { ... } catch (NoNodeException ...)` → `printNodeMeta(null)` is invoked at line 727.
4. `printNodeMeta` has no null check either → `stat.getCzxid()` at line 132 NPEs, and no frame between it and `main` catches `RuntimeException`, so the process terminates with exit code 1.

### Fix (minimal)

Guard the `meta` branch, e.g.:
```java
} else if (cmd.equals("meta") && args.length >= 2) {
    path = args[1];
    stat = zk.exists(path, watch);
    if (stat == null) {
        System.err.println("Node does not exist: " + path);
    } else {
        printNodeMeta(stat);
    }
}
```
(The same latent hazard exists for `get` at line 702 if `exists`-style semantics ever apply, but `zk.getData` throws `NoNodeException` rather than returning null, so only the `meta` path exhibits this bug.)
