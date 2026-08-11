I have the complete diagnosis. Here is the root cause.

## Root Cause

The crash is a classic **"`exists()` returns `null` instead of throwing"** mismatch, unguarded by a null check before dereferencing the `Stat`.

### The failure path

**1. The `meta` command handler — `ZooKeeperMain.java:724–727`**

```java
} else if (cmd.equals("meta") && args.length >= 2) {
    path = args[1];
    stat = zk.exists(path, watch);   // line 726
    printNodeMeta(stat);             // line 727
}
```

Unlike `get`/`setAcl`/`delete`, which call APIs (`getData`, `setACL`, …) that **throw** `KeeperException.NoNodeException` when the path is missing, the `meta` command uses `ZooKeeper.exists(path, watch)`. By ZooKeeper's contract, `exists()` does **not** throw for a nonexistent node — it **returns `null`**.

The log confirms this exactly. The server reply for the bad path carries error code **-101 (NONODE)**:

```
Reading reply ... header:: 8,3  replyHeader:: 8,415,-101  request:: '/app/workers/w4242,F  response::
```

So `zk.exists(...)` returns `null`, and line 726 assigns `stat = null`.

**2. The NPE — `printNodeMeta`, `ZooKeeperMain.java:131–132`**

```java
private static void printNodeMeta(Stat stat) {
    System.err.println("cZxid = 0x" + Long.toHexString(stat.getCzxid()));  // line 132 → NPE
```

`printNodeMeta` is called unconditionally at line 727 with no null check. The very first dereference, `stat.getCzxid()` at **line 132**, throws `java.lang.NullPointerException`.

**3. Why it kills the shell — `processCmd`, `ZooKeeperMain.java:582–594`**

```java
try {
    return processZKCmd(co);
} catch (IllegalArgumentException e) { ... }
  catch (KeeperException.NoNodeException e) {          // line 586
    System.err.println("Node does not exist: " + e.getPath());
} catch (KeeperException.NoChildrenForEphemeralsException e) { ... }
  ...
```

The try/catch around `processZKCmd` only catches `IllegalArgumentException` and specific `KeeperException` subtypes. A `NullPointerException` is an unchecked `RuntimeException` — **not caught here**. It propagates up the exact chain in the stack trace:

`printNodeMeta` (132) → `processZKCmd` (727) → `processCmd` (583) → `executeLine` (355) → `run` (313) → `main` (272)

Nothing in that chain catches it, so the JVM prints `Exception in thread "main" java.lang.NullPointerException` and exits with code 1, ending the interactive session.

### The exact branch conditions

The failure requires **all** of these to hold simultaneously:
1. `cmd.equals("meta") && args.length >= 2` is true → the `meta` branch at line 724 is taken.
2. The target path does **not** exist → server returns NONODE, so `zk.exists(path, watch)` returns `null` (line 726). *(For existing nodes, `exists()` returns a non-null `Stat`, so `printNodeMeta` succeeds — matching the observed "existing nodes print fine" behavior.)*
3. `printNodeMeta(stat)` is invoked at line 727 with `stat == null`, dereferenced at line 132.
4. The unchecked NPE escapes the `catch` list in `processCmd` (lines 584–594), which handles only `IllegalArgumentException` and `KeeperException` subtypes — never `RuntimeException`/`NullPointerException`.

### The fix

Guard against the null `Stat` before printing — the `meta` branch must treat a `null` return from `exists()` as "node does not exist" rather than passing it to `printNodeMeta`. For example, at line 726–727:

```java
stat = zk.exists(path, watch);
if (stat != null) {
    printNodeMeta(stat);
} else {
    System.err.println("Node does not exist: " + path);
}
```

(Equivalently, `printNodeMeta` could early-return on a `null` argument.) The bug is that the `meta` command uniquely relies on `exists()`'s null-return semantics but shares the null-hostile `printNodeMeta` path used by commands whose APIs instead throw the caught `NoNodeException`.
