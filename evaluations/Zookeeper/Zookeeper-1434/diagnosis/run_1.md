Root cause confirmed. Here's the diagnosis:

## Root cause

The shell user ran `meta /app/workers/w4242` (symptom.log:9546). That node does not exist on the server — the reply header at line 9548 carries error `-101` (`NoNode`). The `meta` command handler does not check for a missing node, and dereferences a `null` `Stat` object inside `printNodeMeta`, causing the `NullPointerException`.

## Failure path (branches taken)

1. **`CliShellMain.processCmd` → `processZKCmd` (line 583).**
   Dispatches to the ZooKeeper‑backed command branch.

2. **`processZKCmd` — the `meta` branch (source/src/java/main/org/apache/zookeeper/CliShellMain.java:724‑727):**
   ```java
   } else if (cmd.equals("meta") && args.length >= 2) {
       path = args[1];
       stat = zk.exists(path, watch);   // line 726
       printNodeMeta(stat);             // line 727
   }
   ```
   The condition `cmd.equals("meta") && args.length >= 2` is true (`args = ["meta", "/app/workers/w4242"]`), so this branch executes.

3. **`ZooKeeper.exists(path, watch)` contract:** returns `null` when the node does not exist (instead of throwing `NoNodeException`). Because `/app/workers/w4242` is absent, `stat` is assigned `null`. No null‑check follows; execution falls straight into `printNodeMeta(stat)`.

4. **`printNodeMeta` (source/src/java/main/org/apache/zookeeper/CliShellMain.java:131‑132):**
   ```java
   private static void printNodeMeta(Stat stat) {
       System.err.println("createTxnId = 0x" + Long.toHexString(stat.getCzxid()));
       ...
   }
   ```
   The very first statement dereferences `stat` (`stat.getCzxid()`), throwing `NullPointerException` at line 132 — exactly where the stack trace points.

## The specific defect

The `meta` command handler at lines 724‑727 treats the return of `zk.exists()` as if a `Stat` is always produced, but `zk.exists` returns `null` for a nonexistent path. `printNodeMeta` also unconditionally dereferences its argument at line 132. Either a guard in the `meta` branch (`if (stat == null) { System.err.println("Node does not exist: " + path); } else printNodeMeta(stat);`) or a null‑check at the top of `printNodeMeta` would prevent the crash. The same latent bug exists in the `ls2` branch (line 707‑711), which similarly can pass a stale/unpopulated `stat` to `printNodeMeta`, but the current failure is driven purely by the `meta` path.
