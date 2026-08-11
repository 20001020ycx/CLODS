I have all the evidence needed. Here is the diagnosis.

## Root cause

The `meta` command handler treats the return value of `ZooKeeper.exists()` as if it were always a valid `Stat`, but `exists()` returns **`null`** for a non-existent znode. That `null` is then dereferenced inside `printNodeMeta`, throwing an uncaught `NullPointerException` that propagates all the way out of the read loop and kills the shell.

### The exact failing lines

**`ZooKeeperMain.java:724–727`** — the `meta` command branch:
```java
} else if (cmd.equals("meta") && args.length >= 2) {   // 724
    path = args[1];                                    // 725
    stat = zk.exists(path, watch);                     // 726  <-- returns null when path doesn't exist
    printNodeMeta(stat);                               // 727  <-- passes null onward
```

**`ZooKeeperMain.java:131–132`** — the actual NPE site:
```java
private static void printNodeMeta(Stat stat) {                          // 131
    System.err.println("cZxid = 0x" + Long.toHexString(stat.getCzxid())); // 132  <-- stat.getCzxid() on null -> NPE
```

### The exact logical conditions (branches) that dictate the failure

1. **Command dispatch branch — `cmd.equals("meta") && args.length >= 2` (line 724).** Entering this branch is required; other paths don't call `zk.exists`.

2. **`zk.exists(path, watch)` (line 726) is the pivotal condition.** `ZooKeeper.exists` is *defined* to return `null` when the node is absent (it does **not** throw `NoNodeException`, unlike `getData`/`getChildren`). So the outcome forks on server state:
   - **Path exists** → non-null `Stat` → `printNodeMeta` prints fine (this is why existing znodes work).
   - **Path does NOT exist** → `stat = null`.

   The server still answers the `exists` RPC normally (this is why the server log shows nothing abnormal — the failure is purely client-side).

3. **`printNodeMeta(stat)` with `stat == null` (line 727 → 132).** The very first statement dereferences `stat.getCzxid()`, raising `NullPointerException`.

### Why the whole shell process dies (JVM exit 1)

The NPE is a `RuntimeException`, and **nothing on the call stack catches it**:

- `processCmd` (lines 582–595) wraps `processZKCmd` in a `try` that only catches `IllegalArgumentException` and specific `KeeperException` subtypes (`NoNodeException`, `NoChildrenForEphemeralsException`, `NodeExistsException`, `NotEmptyException`). `NullPointerException` matches none of these, so it passes straight through.
- `executeLine` (line 355) calls `processCmd` and declares `throws ... KeeperException` but has no `try/catch`.
- The interactive read loop in `run()` (lines 312–313 for jline, or 338–339 for the plain `BufferedReader`) calls `executeLine` unguarded.
- The exception therefore unwinds out of `run()` → `main()` (declared `throws KeeperException, IOException, InterruptedException`), reaches the JVM's default uncaught-exception handler, which prints the stack trace and terminates the process with **exit code 1**. The read loop never gets another iteration, so the rest of the session is lost.

### Contrast with commands that don't fail

The other metadata-printing commands avoid this because they use API calls that **throw** `NoNodeException` (which `processCmd` *does* catch) rather than returning `null`:
- `get` (line 699, `zk.getData`), `ls2` (line 709, `zk.getChildren`), `set` (691), `getAcl` (714) etc. — on a missing node these throw `KeeperException.NoNodeException`, caught at line 586, printing `"Node does not exist: ..."` and keeping the shell alive.

`meta` is the lone branch that relies on `exists()`'s null-return contract yet feeds the result into a method (`printNodeMeta`) that unconditionally dereferences it — with no null check at line 726/727 and no `NullPointerException`/generic catch in `processCmd`.

### The fix
Guard the null before printing, e.g. in the `meta` branch:
```java
stat = zk.exists(path, watch);
if (stat != null) {
    printNodeMeta(stat);
} else {
    System.err.println("Node does not exist: " + path);
}
```
(Alternatively, null-guard inside `printNodeMeta`, and/or broaden `processCmd`'s catch to handle unexpected runtime exceptions instead of letting them kill the shell.)
