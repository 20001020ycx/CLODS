## Root cause

The follower's `CommitProcessor.needCommit(...)` does not list `OpCode.create2` (the wire name printed in the logs is `createExt`). When a `create(path, data, acl, mode, Stat)` request arrives at the follower, it falls through the switch to the `default` branch and is treated as a read; the follower dispatches it straight to `FinalRequestProcessor` without ever forwarding it to the leader or waiting for a commit. `FinalRequestProcessor` then calls `ZKDatabase.addCommittedProposal(request)` (because `Request.isQuorum()` *does* include `create2`), which dereferences the still-null `request.hdr` and throws NPE. The `CommitWorkRequest.cleanup` hook reacts to the exception by permanently halting the `CommitProcessor`, so from that instant on every request on that follower — including sessions that reconnect to it — is silently dropped and eventually reported to the client as `ConnectionLoss`.

### The exact lines and branches

1. **The missing opcode — the primary defect**
   `source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java` lines 131‑148:
   ```java
   protected boolean needCommit(Request request) {
       switch (request.type) {
           case OpCode.create:
           case OpCode.delete:
           case OpCode.setData:
           case OpCode.reconfig:
           case OpCode.multi:
           case OpCode.setACL:
               return true;
           ...
           default:
               return false;   //  <-- create2 (createExt) lands here
       }
   }
   ```
   `OpCode.create2` is absent, so `needCommit` returns `false` for the `create-with-Stat` opcode.

2. **The false-read dispatch that follows**
   Same file, lines 169‑177 — the run-loop branch taken because `needCommit` returned `false`:
   ```java
   if (needCommit(request)) {
       nextPending.set(request);          // NOT taken for create2
   } else {
       sendToNextProcessor(request);      // <-- taken: goes straight to Final...
   }
   ```
   The request is sent to `FinalRequestProcessor` with `request.hdr == null` and `request.zxid == 0xfffffffffffffffe` (visible in the log at line 1874: `type:createExt cxid:0x4 zxid:0xfffffffffffffffe txntype:unknown`).

3. **The inconsistent classification that turns the mistake into a crash**
   `source/src/java/main/org/apache/zookeeper/server/Request.java` lines 161‑185 — `isQuorum()` *does* include `create2`:
   ```java
   case OpCode.create:
   case OpCode.createExt:      // <-- returns true
       ...
       return true;
   ```
   So `FinalRequestProcessor` enters the quorum-only branch even though the request has no header.

4. **The NPE site**
   `source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java` lines 126‑128:
   ```java
   if (request.isQuorum()) {                  // true for createExt
       zks.getZKDatabase().addCommittedProposal(request);
   }
   ```
   which reaches `source/src/java/main/org/apache/zookeeper/server/ZKDatabase.java` line 251:
   ```java
   request.getHdr().serialize(boa, "hdr");    // NPE: hdr is null
   ```
   This is exactly the stack trace at log line 1876‑1883.

5. **Why the follower goes permanently dark after this single NPE**
   `CommitProcessor.java` lines 283‑290 (`CommitWorkRequest.cleanup`):
   ```java
   public void cleanup() {
       if (!stopped) {
           LOG.error("Exception thrown by downstream processor,"
                     + " unable to continue.");
           CommitProcessor.this.halt();       // <-- sets stopped = true, stops worker pool
       }
   }
   ```
   Once `halt()` runs (log line 1884, then 1885 `"CommitProcessor exited loop!"`), every subsequent call is short-circuited:
   - `processRequest` (line 333‑335) — `if (stopped) return;`
   - `commit` (line 320‑323) — `if (stopped || request == null) return;`

   The `NIOServerCnxn`/session layer is still alive, so the follower keeps accepting TCP connections and even revalidates sessions via the leader (log lines 1892‑…: `Learner@115 - Revalidating client`), but no request past that point can ever be answered. Clients therefore see `ConnectionLoss` on read timeout, reconnect to the same follower (session is still valid on the leader), and time out again — precisely the symptom.

### Summary

The root cause is a one-line omission in `CommitProcessor.needCommit` (`OpCode.create2` is missing from the list of ops that must wait for a quorum commit). On a follower, this misclassifies `create(..., Stat)` as a local read; `FinalRequestProcessor.addCommittedProposal` then NPEs on the null header (`ZKDatabase.java:251`), which triggers `CommitWorkRequest.cleanup` → `CommitProcessor.halt()` (`CommitProcessor.java:288`), turning that follower into a black hole for all subsequent client traffic while the rest of the ensemble stays healthy.
