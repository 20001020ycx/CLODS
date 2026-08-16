## Root cause

The crash is a null-`Stat` dereference in the `meta` command path when the target znode does not exist.

**Trigger (from `symptom.log:9546-9548`):** the user ran `meta /app/workers/w4242`. The ZooKeeper server replied with error code `-101` (`NoNodeException`) — the path does not exist.

**Failure path:**

1. `CliShellMain.java:724-727` handles `meta`:
   ```java
   } else if (cmd.equals("meta") && args.length >= 2) {
       path = args[1];
       stat = zk.exists(path, watch);   // returns null when the node doesn't exist
       printNodeMeta(stat);              // called unconditionally
   }
   ```
   The `zk.exists(path, watch)` API is defined to **return `null`** (rather than throw) when the node is missing. The branch does not null-check the returned `stat` before passing it downstream.

2. `CliShellMain.java:131-132` in `printNodeMeta`:
   ```java
   private static void printNodeMeta(Stat stat) {
       System.err.println("createTxnId = 0x" + Long.toHexString(stat.getCzxid()));
       ...
   }
   ```
   The very first statement dereferences `stat` via `stat.getCzxid()`. Because `stat == null`, this throws `NullPointerException`, which propagates uncaught up through `processZKCmd` → `processCmd` → `executeLine` → `run` → `main`, terminating the JVM with exit code 1.

**Exact logical condition that dictates the crash:** the `meta` branch is taken (`cmd.equals("meta") && args.length >= 2`) **and** the argument path does not exist on the server, so `zk.exists()` returns `null` instead of a `Stat`. The bug is the missing `if (stat != null)` guard around the `printNodeMeta(stat)` call at line 727 (equivalently, the missing null check at the top of `printNodeMeta` at line 131). Other commands that use `printNodeMeta` (`get`, `ls2`, `setAcl`) obtain `stat` from calls that either populate an out-parameter on success or throw `NoNodeException` on failure, so they don't hit this path — only the `meta` branch turns a missing node into a silent `null` `Stat`.
