I have the complete diagnosis.

## Root Cause

The crash is a **null-dereference in the zkCli client** caused by feeding the result of `ZooKeeper.exists()` (which returns `null` for a non-existent znode) straight into `printNodeMeta()`, which unconditionally dereferences it.

### The failure path

**1. The `meta` command handler — `ZooKeeperMain.java:724–727`**

```java
} else if (cmd.equals("meta") && args.length >= 2) {
    path = args[1];
    stat = zk.exists(path, watch);   // line 726 — returns null when the node does not exist
    printNodeMeta(stat);             // line 727 — passes null onward, no null check
}
```

`ZooKeeper.exists(path, watch)` is contractually defined to return **`null` when the znode does not exist** (and a populated `Stat` when it does). The server processes the request perfectly and truthfully answers "no such node" by returning `null` — this is normal, expected behavior, not a server error, which is why the server logs show nothing wrong. The handler never checks for that `null` before calling `printNodeMeta`.

**2. The unconditional dereference — `ZooKeeperMain.java:131–132`**

```java
private static void printNodeMeta(Stat stat) {
    System.err.println("cZxid = 0x" + Long.toHexString(stat.getCzxid()));  // line 132 — NPE here
    ...
```

With `stat == null`, the very first line, `stat.getCzxid()`, throws `java.lang.NullPointerException`.

**3. Why the whole shell dies (JVM exit 1) — `ZooKeeperMain.java:310–314`**

```java
while ((line = (String)readLine.invoke(console, getPrompt())) != null) {
    executeLine(line);   // line 313
}
```

The command loop's `try/catch` (lines 315–330) only catches the *reflection* checked exceptions used to bootstrap JLine — `ClassNotFoundException`, `NoSuchMethodException`, `InvocationTargetException`, `IllegalAccessException`, `InstantiationException`. It catches **no** `RuntimeException`/`NullPointerException`. So the NPE thrown in `printNodeMeta` propagates out of `executeLine` → out of the `while` read loop → out of `run()` → out of `main()`, terminating the process with exit code 1 and losing the interactive session. (The non-JLine fallback loop at lines 338–339 has no surrounding catch either.)

### The exact conditions (branches) that must hold

1. `cmd.equals("meta") && args.length >= 2` is true (line 724) → the `meta` branch runs.
2. The path argument names a znode that **does not exist**, so `zk.exists(path, watch)` returns `null` (line 726). *(For an existing node it returns a non-null `Stat`, so `printNodeMeta` succeeds and prints normally — exactly matching "the same command against znodes that do exist works.")*
3. `printNodeMeta(null)` dereferences `stat` at line 132, throwing NPE.
4. Neither the JLine loop's catch block (only reflection exceptions) nor the fallback loop catches the runtime exception, so it escapes `main` and kills the JVM.

### The fix

Guard the `null` in the `meta` branch, e.g.:

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

(Making `printNodeMeta` null-tolerant would also help, but the missing-node check belongs in the `meta` branch, mirroring how other commands surface a "does not exist" message instead of crashing.)
