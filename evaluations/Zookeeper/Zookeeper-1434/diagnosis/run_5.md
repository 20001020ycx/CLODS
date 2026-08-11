The diagnosis is complete and confirmed. Here is the root cause.

## Root Cause

The `meta` command in the zkCli shell crashes with an unhandled `NullPointerException` because it passes the return value of `ZooKeeper.exists()` straight into `printNodeMeta()` without a null check. For a **non-existent** path, `exists()` returns `null` (rather than throwing), so `printNodeMeta` dereferences a `null` `Stat`.

### The failure path — exact lines

**`ZooKeeperMain.java:724-727`** — the `meta` branch of `processZKCmd`:

```java
} else if (cmd.equals("meta") && args.length >= 2) {   // 724
    path = args[1];
    stat = zk.exists(path, watch);                      // 726  -> returns null for missing node
    printNodeMeta(stat);                                // 727  -> passes null downstream
```

The condition that selects this branch: `cmd.equals("meta") && args.length >= 2`. The critical implicit branch is that **`zk.exists()` returns `null`** when the znode does not exist. By ZooKeeper's API contract, `exists()` does *not* throw `NoNodeException` for a missing node — it signals absence by returning `null`. This is exactly why "znodes that do exist" work fine (non-null `Stat`) while a missing path returns `null`.

**`ZooKeeperMain.java:131-132`** — the actual NPE site:

```java
private static void printNodeMeta(Stat stat) {
    System.err.println("cZxid = 0x" + Long.toHexString(stat.getCzxid())); // 132 -> stat is null -> NPE
```

The first statement, `stat.getCzxid()`, dereferences the `null` argument and throws `java.lang.NullPointerException`.

### Why it kills the whole shell (JVM exit code 1)

**`ZooKeeperMain.java:582-595`** — `processCmd`'s try/catch only catches `IllegalArgumentException` and a fixed set of `KeeperException` subtypes:

```java
try {
    return processZKCmd(co);
} catch (IllegalArgumentException e) { ...
} catch (KeeperException.NoNodeException e) { ...
} ...   // no catch for RuntimeException / NullPointerException
```

`NullPointerException` is an unchecked `RuntimeException` and matches **none** of these catch clauses. It therefore propagates uncaught up through `executeLine()` (line 355) and out of `main`'s interactive read loop (the `executeLine(line)` call around line 313/339), which has no guard for it either. The uncaught exception terminates the `main` thread, the JVM prints the stack trace and exits with code 1 — ending the interactive session, even though the server answered the `exists` request normally.

### Summary of the exact logical conditions

1. `cmd.equals("meta") && args.length >= 2` selects the meta branch (line 724).
2. `zk.exists(path, watch)` returns `null` because the path does not exist (line 726) — the decisive branch; an existing path returns a non-null `Stat` and works.
3. `printNodeMeta(null)` dereferences `stat.getCzxid()` → NPE (lines 727 → 132).
4. The NPE is a `RuntimeException` not covered by `processCmd`'s catch list (lines 582–595), so it escapes the command loop and kills the JVM.

**The fix** would be a null guard before line 727, e.g. `if (stat != null) printNodeMeta(stat); else System.err.println("Node does not exist: " + path);`, mirroring how ZooKeeper's later `stat` command handles the missing-node case.
