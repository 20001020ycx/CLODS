# Ground truth — Zookeeper-1434  (NEVER shown to the diagnosis LLM)

Derived from `private/fix.diff` = upstream commit `7f64942ba8e5ce00948f6e7b23271de0556b668f`
("stat command isses on non-existing node causes NPE", fixVersion 3.4.0), which is the
commit that resolves the defect reported in this ticket (the ticket itself was closed
Won't Fix **for the 3.3 branch only**, because the same change had already landed on trunk;
the 3.3 patch attached to the ticket, `private/jira-1434-attached-3.3-patch.diff`, is the
identical edit). Pre-fix tree = `59ac9fa78`.

## Name cross-reference (real ↔ anonymized)

The LLM answers in **anonymized** names; translate with this table (full detail in
`private/anonymization_map.json`) before matching by code identity.

| real (pre-fix tree) | anonymized (in `source/`) |
|---|---|
| `ZooKeeperMain.java` / class `ZooKeeperMain` | `CliShellMain.java` / class `CliShellMain` |
| CLI command `stat` | CLI command `meta` |
| `printStat(Stat stat)` | `printNodeMeta(Stat stat)` |
| `System.err.println("cZxid = 0x" + Long.toHexString(stat.getCzxid()))` | `System.err.println("createTxnId = 0x" + Long.toHexString(stat.getCzxid()))` |
| `System.err.println("Node does not exist: " + e.getPath())` | `System.err.println("No such node: " + e.getPath())` |
| `LOG.debug("Processing " + cmd)` | `LOG.debug("Dispatching command: " + cmd)` |

Unchanged (real) everywhere: `processZKCmd`, `processCmd`, `executeLine`, `run`, `main`,
`ZooKeeper.exists`, `KeeperException`, `Stat`, package paths. Line numbers below are those
of the anonymized build in `source/`; they coincide with the pre-fix tree's, since the
renames are in-place edits.

## The root-causing line(s)

**File:** real `…/zookeeper/ZooKeeperMain.java` → anonymized `source/src/java/main/org/apache/zookeeper/CliShellMain.java`
**Method:** `protected boolean processZKCmd(MyCommandOptions co)`

```java
724:        } else if (cmd.equals("meta") && args.length >= 2) {   // real: cmd.equals("stat")
725:            path = args[1];
726:            stat = zk.exists(path, watch);      // <-- returns NULL when the znode is absent
727:            printNodeMeta(stat);                // <-- null passed straight through: ROOT CAUSE
728:        } else if (cmd.equals("listquota") && args.length >= 2) {
```

The fix inserts the missing guard between 726 and 727:

```java
            stat = zk.exists(path, watch);
+           if (stat == null) {
+             throw new KeeperException.NoNodeException(path);
+           }
            printStat(stat);        // anonymized: printNodeMeta(stat)
```

**Crash site (where the NPE is actually thrown, given by the stack trace — necessary but
not sufficient on its own):**
`printNodeMeta(Stat stat)` (real `printStat`), line 132:
`System.err.println("createTxnId = 0x" + Long.toHexString(stat.getCzxid()));` — the first
dereference of the `null` argument. The printer has no null check either.

## The exact branch conditions that dictate the failure path

1. **Dispatch branch taken:** `cmd.equals("meta") && args.length >= 2` (line 724; real:
   `cmd.equals("stat")`). This is the **only** command branch whose handler obtains its
   `Stat` from `ZooKeeper.exists(path, watch)`.
2. **The condition that is missing (the wrong branch logic):** there is **no
   `if (stat == null)` test** between `stat = zk.exists(path, watch)` (726) and
   `printNodeMeta(stat)` (727). `ZooKeeper.exists()` is documented and implemented to
   **return `null` rather than throw** when the node does not exist
   (`source/src/java/main/org/apache/zookeeper/ZooKeeper.java`: "Return the stat of the node
   of the given path. Return null if no such a node exists."; the client converts the
   server's `NoNode` (`KeeperException.Code.NONODE`, wire error `-101`) into `null` — see
   `ZooKeeper.exists(String, Watcher)` lines 912-916:
   `if (r.getErr() != 0) { if (r.getErr() == KeeperException.Code.NONODE.intValue()) { return null; } … }`,
   plus the trailing `return response.getStat().getCzxid() == -1 ? null : response.getStat();`).
   Every other command's handler either passes a caller-allocated `Stat` into an API that
   throws `NoNodeException` on a missing node (`get`, `ls2`, `set`, `setAcl`, `getAcl`) or
   does not print a `Stat` at all — so this is the sole path on which a `null Stat` can
   reach the printer.
   Hence the failure path is exactly: `cmd == "meta"` ∧ `zk.exists(path, watch) == null`
   (i.e. the path does not exist) → unchecked `printNodeMeta(null)` → NPE at the first
   `stat.getCzxid()`.
3. **Why the shell dies instead of printing an error:** `processCmd` (lines 579-596) wraps
   `processZKCmd` in a try/catch whose handlers are `IllegalArgumentException`,
   `KeeperException.NoNodeException`, `KeeperException.NoChildrenForEphemeralsException`,
   `KeeperException.NodeExistsException` and `KeeperException.NotEmptyException`. A
   `NullPointerException` matches none of them, so it escapes `processCmd` → `executeLine`
   → the `run()` read loop (whose own catch list is `ClassNotFoundException`/
   `NoSuchMethodException`/`InvocationTargetException`/`IllegalAccessException`/
   `InstantiationException`) → `main`, killing the JVM. Throwing `NoNodeException` instead
   — as the fix does — lands in the existing `catch (KeeperException.NoNodeException e)`
   arm, which prints `"No such node: " + e.getPath()` (real: `"Node does not exist: "`) and
   keeps the session alive.

## Grading rule for this bug (see METHODOLOGY §8 — no partial credit)

A run **PASSes** iff it states **both**:

- **(L)** the root-causing location: in `processZKCmd`, the `meta` command branch, the
  `stat = zk.exists(path, watch)` → `printNodeMeta(stat)` pair (line 726/727) where the
  unchecked value is passed on — equivalently, "the missing null check before
  `printNodeMeta` in the `meta` branch". Naming **only** the crash line inside
  `printNodeMeta` (line 132) without identifying the unguarded `exists()` result in the
  `meta` branch is **not** enough (that line is handed to the model by the stack trace).
- **(B)** the exact branch condition: the failure requires the branch
  `cmd.equals("meta") && args.length >= 2` **and** the absent `stat == null` guard, on the
  ground that `ZooKeeper.exists()` returns `null` (rather than throwing
  `NoNodeException`/NONODE `-101`) when the znode does not exist.

Naming the fix's remedy (`throw new KeeperException.NoNodeException(path)` / a null check)
is not required but is corroborating evidence. Point 3 (the catch chain that lets the NPE
kill the process) is explanatory context, not required for a PASS.

Note on difficulty after the M5 revision: `symptom.md` is now only the pasted stack trace,
so the model is **not** told that the command targeted a non-existent path, nor which
command it was. It must find the triggering line in the log itself and derive the
null-return contract from the source.
