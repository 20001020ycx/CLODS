I have traced the complete failure path and it matches the log numbers exactly. Here is the root cause.

## Root cause

`DatanodeDescriptor.resetBlocks()` zeroes every derived usage field **except `otherUsed`**.

`/bug/source/.../blockmanagement/DatanodeDescriptor.java:313`
```java
public void resetBlocks() {
  setCapacity(0);
  setRemaining(0);
  setBlockPoolUsed(0);
  setDfsUsed(0);
  setXceiverCount(0);
  ...
  // <-- setOtherUsed(0) is MISSING
}
```

`resetBlocks()` is called when a datanode is declared dead (`BlockManager.removeBlocksAssociatedTo`, `BlockManager.java:1124`). Because it forgets `otherUsed`, the dead descriptor keeps a **stale** `otherUsed = 5000`, while `capacity`/`dfsUsed`/etc. are correctly cleared to 0. The cluster‑wide `capacityUsedOther` in `HeartbeatManager.Stats` is maintained purely by paired `add`/`subtract` calls that read these descriptor fields — so the one field that isn't reset breaks the pairing and gets counted twice.

## The exact branch sequence (matches the log)

Values: dn1 = dn2 = `otherUsed 5000`, `capacity 20000`. Start: `capOther=10000`, `capT=40000`.

**1. dn1 declared dead** — `HeartbeatManager.heartbeatCheck` (`296` `isDatanodeDead` true) → `DatanodeManager.removeDeadDatanode` (`585` true) → `removeDatanode` (`543`):
- `heartbeatManager.removeDatanode` — `210` `if (node.isAlive)` true → `stats.subtract` (`211`) reads `otherUsed=5000` → `capOther 10000→5000`, `capT 40000→20000`. `isAlive=false`.
- `blockManager.removeBlocksAssociatedTo` → `resetBlocks()` (`1124`): sets capacity/dfsUsed/… = 0, **leaves `otherUsed=5000`**.

  → log: `PROBE dead: cluster_otherUsed=5000 ... capacityTotal=20000` ✓ (still correct). Descriptor is **not** wiped from `datanodeMap`/`host2DatanodeMap`.

**2. dn1 re‑registers** — `DatanodeManager.registerDatanode`: `nodeS!=null` (`885`) and `nodeN==nodeS` (`886`, "node restarted" branch) → `heartbeatManager.register(nodeS)` (`934`):
- `HeartbeatManager.register` `190` `if (!d.isAlive)` true → `addDatanode` → `stats.add` (`204`/`409` `capacityUsedOther += node.getOtherUsed()`) reads the **stale 5000** → `capOther 5000→10000`; capacity adds 0 (was reset) → `capT` stays 20000.
- `d.updateHeartbeatState(EMPTY_ARRAY,…)` (`194`): empty reports → `totalOtherUsed=0` → `setOtherUsed(0)` (`436`). Descriptor `otherUsed` now 0.

  This `add` has **no matching subtract** — `capOther` is already wrong (10000) here.

**3. dn1's first real heartbeat** — `HeartbeatManager.updateHeartbeat` (`217`):
- `stats.subtract(node)` (`221`/`426`) reads `otherUsed=0` → subtracts nothing.
- `node.updateHeartbeat` sets `otherUsed=5000`.
- `stats.add(node)` (`224`/`409`) adds 5000 → `capOther 10000→15000`; capacity subtract 0 / add 20000 → `capT 20000→40000`.

  → log: `PROBE rereg: cluster_otherUsed=15000 ... capacityTotal=40000` → **SYMPTOM: observed=15000 expected=10000**. ✓

## Why only `otherUsed` is wrong

`capacity`/`dfsUsed`/`blockPoolUsed`/`remaining` are spared because `resetBlocks()` zeroes them: at step 2 the re‑registration `stats.add` reads 0 for those, so the add/subtract pairing stays balanced (final `capacityTotal=40000`, correct). `otherUsed` is the single field `resetBlocks()` omits, so its stale value gets injected by the unpaired `add` and then re‑added by the heartbeat — a double count that persists.

**Fix locus (not applied):** `resetBlocks()` at `DatanodeDescriptor.java:313` must also `setOtherUsed(0)` so a dead node's descriptor carries no stale other‑used value into re‑registration.
