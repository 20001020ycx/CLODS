Root cause confirmed. I have everything I need.

## Root Cause

The failure is a **null-pointer dereference in the zkCli client's `meta` command handler**, caused by unconditionally passing the result of `ZooKeeper.exists()` into a method that never null-checks it.

### The failure path (three specific lines)

**1. `ZooKeeperMain.java:724-727` — the `meta` command handler (`processZKCmd`)**
```java
} else if (cmd.equals("meta") && args.length >= 2) {
    path = args[1];
    stat = zk.exists(path, watch);   // line 726
    printNodeMeta(stat);             // line 727  <-- passes stat unconditionally
}
```

**2. The `zk.exists()` contract** — Unlike `getData`/`getACL`, `ZooKeeper.exists(path, watch)` does **not** throw on a missing node. Its documented, by-design behavior is to return a `Stat` object if the znode exists and to return **`null`** if it does not. The server reports the absence via error code, but the client library translates a `NoNode` (`-101`) result of an `exists` op into a plain `null` return rather than a `KeeperException`. So for a nonexistent path, `stat` is assigned `null` and control proceeds normally to line 727.

**3. `ZooKeeperMain.java:131-132` — `printNodeMeta(Stat stat)`**
```java
private static void printNodeMeta(Stat stat) {
    System.err.println("cZxid = 0x" + Long.toHexString(stat.getCzxid()));  // line 132  <-- NPE
```
The first statement dereferences `stat.getCzxid()`. When `stat == null`, this throws the unhandled `java.lang.NullPointerException`. Because `processZKCmd` → `processCmd` → `executeLine` → `run` → `main` have no surrounding try/catch for RuntimeExceptions on this path, the exception propagates out of `main`, and the JVM terminates the entire interactive shell with exit code 1.

### The exact branch conditions that dictate the failure

The crash requires **all** of the following to hold simultaneously:

1. **Command dispatch:** `cmd.equals("meta") && args.length >= 2` is true (line 724) — i.e., the operator typed `meta <path>`.
2. **Server response branch:** The path passed to `zk.exists()` refers to a **nonexistent** znode. This makes the `exists` operation resolve to the "node absent" case, so the client returns `null` instead of a populated `Stat`. This is precisely what the log shows: the reply header for `/app/workers/w4242` is `replyHeader:: 8,415,-101` — err code **-101 = NoNode** — followed immediately by the NPE trace.
3. **No guard:** There is **no `if (stat != null)` branch** between the `exists` call (726) and the `printNodeMeta` call (727), and `printNodeMeta` itself has no null-check before dereferencing `stat` at line 132.

### Why existing znodes are fine
For a path that exists (e.g. `meta /app/config/key1`, `meta /app/workers/w42` in the log, both with `replyHeader ...,0` = OK), `zk.exists()` returns a non-null `Stat`, so `printNodeMeta` dereferences a valid object and prints the metadata normally. The bug is triggered *only* on the missing-node branch.

### The fix
Guard the print, mirroring how the other read commands behave — e.g.:
```java
} else if (cmd.equals("meta") && args.length >= 2) {
    path = args[1];
    stat = zk.exists(path, watch);
    if (stat != null) {
        printNodeMeta(stat);
    }   // else: print a "node does not exist" message instead of crashing
}
```
(Equivalently, `printNodeMeta` could early-return on `stat == null`.) The essential defect is that `exists()`'s legitimate `null`-on-absence return value is treated as if it were always a valid `Stat`.
