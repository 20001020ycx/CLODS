## Root cause

The failing command in the log is `meta /app/workers/w4242` (line 9546 of the log), a znode that was never created. The reply header from ZooKeeper carries error code `-101` (`NoNode`), so `ZooKeeper.exists(...)` returned `null` — the documented behaviour when the queried path does not exist.

## Faulty code path

`CliShellMain.processZKCmd`, the `meta` branch — `source/src/java/main/org/apache/zookeeper/CliShellMain.java:724-727`:

```java
} else if (cmd.equals("meta") && args.length >= 2) {
    path = args[1];
    stat = zk.exists(path, watch);   // returns null when node is absent
    printNodeMeta(stat);              // <-- passes null through, no guard
}
```

`printNodeMeta` immediately dereferences its argument at `CliShellMain.java:132`:

```java
private static void printNodeMeta(Stat stat) {
    System.err.println("createTxnId = 0x" + Long.toHexString(stat.getCzxid())); // NPE here
    ...
}
```

## Exact branch that dictates the failure

1. In `run()`→`executeLine()`→`processCmd()`→`processZKCmd()`, the parsed command satisfies `cmd.equals("meta") && args.length >= 2`, so control enters the `meta` branch at line 724.
2. `zk.exists(path, watch)` is called with a non‑existent path (`/app/workers/w4242`); by the ZooKeeper API contract this returns `null` rather than throwing.
3. There is no `if (stat == null)` check between lines 726 and 727; `printNodeMeta(stat)` is called unconditionally.
4. Inside `printNodeMeta` (line 131), the first statement (line 132) invokes `stat.getCzxid()` on the null reference, producing the uncaught `NullPointerException` that propagates all the way back to `main` and terminates the JVM with exit code 1.

The bug is the missing null‑check on the return value of `zk.exists(...)` in the `meta` handler at line 726 — every other information‑display branch (`get`, `ls2`) obtains its `Stat` from calls (`getData`, `getChildren`) that throw `NoNodeException` on a missing path, whereas `exists` uniquely signals "not found" by returning `null`, and this branch doesn't handle that case before dereferencing.
