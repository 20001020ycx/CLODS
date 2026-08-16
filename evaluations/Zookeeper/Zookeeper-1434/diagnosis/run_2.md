## Root cause

The `meta` command on a non-existent znode triggers an unguarded null dereference.

**Trigger from the log** (`logs/symptom.log:9546-9549`): the user typed `meta /app/workers/w4242`. The server's reply-header error code is `-101` (`KeeperException.Code.NONODE`) — the znode does not exist. The next line is the `NullPointerException`.

**Fault path in the source** (`src/java/main/org/apache/zookeeper/CliShellMain.java`):

1. `processZKCmd` dispatches the `meta` command at lines 724–727:
   ```java
   } else if (cmd.equals("meta") && args.length >= 2) {
       path = args[1];
       stat = zk.exists(path, watch);   // line 726
       printNodeMeta(stat);              // line 727
   }
   ```
   The condition taken is `cmd.equals("meta") && args.length >= 2`. `ZooKeeper.exists(path, watch)` is documented to **return `null` when the node does not exist** (instead of throwing `NoNodeException`). Because `w4242` doesn't exist, `stat` is set to `null`. There is no `if (stat != null)` guard before the call to `printNodeMeta`.

2. `printNodeMeta` at lines 131–132 immediately dereferences its argument:
   ```java
   private static void printNodeMeta(Stat stat) {
       System.err.println("createTxnId = 0x" + Long.toHexString(stat.getCzxid()));  // line 132 — NPE here
   ```
   With `stat == null`, `stat.getCzxid()` throws the `NullPointerException` seen in the stack trace.

3. The exception unwinds through `processZKCmd:727 → processCmd:583 → executeLine:355 → run:313 → main:272`, none of which catch `NullPointerException` (the surrounding `try` blocks only handle `KeeperException`/`InterruptedException`/`IOException`), so the JVM exits with code 1.

**Exact logical condition that dictates the failure**: the branch `cmd.equals("meta") && args.length >= 2` is taken while the target path does not exist on the server, so `zk.exists(...)` returns `null`, and `printNodeMeta(null)` unconditionally calls `stat.getCzxid()` at `CliShellMain.java:132`. Compare with the sibling `getAcl`/`ls2` branches, which get `stat` populated as an out-parameter by the ZK call and therefore don't hit this hazard — the `meta` branch is unique in relying on the return value of `exists`, which is nullable by contract.

Fix would be to guard the call, e.g. `if (stat != null) printNodeMeta(stat); else System.err.println("Node does not exist: " + path);` at line 726–727.
