I have the complete failure path. The log confirms exactly what the code paths predict — an NPE at `ZKDatabase.java:251` inside `FinalRequestProcessor.processRequest` on the `createExt` op that never got a `TxnHeader`, followed by `CommitProcessor exited loop!` and then a cascade of `Unable to read additional data` / renewed sessions that time out again.

## Root cause

The `create(path,data,acl,mode,Stat)` overload uses a distinct opcode, `OpCode.createExt = 15` (`ZooKeeper.java:1143`, `ZooDefs.java:60`). Three dispatch tables on the server were never taught about it, so on a **follower** the op skips both the "forward to leader" and the "wait for commit" branches, then trips a null-deref inside a code path that *does* know about `createExt` and treats the request as if a proposal had been committed for it.

### The three branch defects (in the exact order the request hits them)

1. **`FollowerRequestProcessor.run()` — the forward-to-leader switch**
   `source/src/java/main/org/apache/zookeeper/server/quorum/FollowerRequestProcessor.java:79-100`
   ```java
   switch (request.type) {
     case OpCode.sync:        ...
     case OpCode.create:      // ← plain create is here
     case OpCode.delete:
     case OpCode.setData:
     case OpCode.reconfig:
     case OpCode.setACL:
     case OpCode.multi:
     case OpCode.check:
         zks.getFollower().request(request);   // forward to leader
         break;
     ...
   }
   ```
   `OpCode.createExt` is missing. The request is handed to `nextProcessor` at line 72 but **never shipped to the leader** — that is why the znode is never created anywhere, on any ensemble member.

2. **`CommitProcessor.needCommit()` — the wait-for-commit predicate**
   `source/src/java/main/org/apache/zookeeper/server/quorum/CommitProcessor.java:131-148`
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
         default: return false;
       }
   }
   ```
   `OpCode.createExt` is missing here too, so `needCommit()` returns **false**. In `run()` at line 172-176 the request therefore takes the `else`-branch (`sendToNextProcessor(request)`) instead of being parked in `nextPending` — it is passed straight down to `FinalRequestProcessor` with `request.getHdr() == null` (no proposal ever arrived, and never will).
   The log line 1873→1874 shows exactly this: `type:createExt … zxid:0xfffffffffffffffe txntype:unknown` enters `CommitProcessor` and, at the same millisecond, is picked up by `FinalRequestProcessor`.

3. **`FinalRequestProcessor.processRequest()` + `Request.isQuorum()` — the fatal combination**
   `source/src/java/main/org/apache/zookeeper/server/FinalRequestProcessor.java:126-128`
   ```java
   if (request.isQuorum()) {
       zks.getZKDatabase().addCommittedProposal(request);
   }
   ```
   `Request.isQuorum()` at `Request.java:169-170` **does** include `case OpCode.createExt: return true;`. So this branch is entered — even though `request.getHdr()` is still `null`.
   Inside `addCommittedProposal`, `source/src/java/main/org/apache/zookeeper/server/ZKDatabase.java:251`:
   ```java
   request.getHdr().serialize(boa, "hdr");   // NPE — getHdr() is null
   ```
   The NPE at log line 1875-1883 originates exactly here.

### Why the follower then stops answering *everybody*

`FinalRequestProcessor.processRequest` runs inside `CommitProcessor$CommitWorkRequest.doWork()` (`CommitProcessor.java:292-314`). The uncaught NPE fires the wrapper's `cleanup()` (lines 284-290):

```java
public void cleanup() {
    if (!stopped) {
        LOG.error("Exception thrown by downstream processor, unable to continue.");
        CommitProcessor.this.halt();   // ← kills the processor for this JVM
    }
}
```

`halt()` (lines 346-353) sets `stopped = true`, wakes the main loop (which promptly exits — logged as `CommitProcessor exited loop!` at line 1885), clears `queuedRequests`, and stops the worker pool. From then on, `CommitProcessor.processRequest` (line 333-335) short-circuits on `if (stopped) return;` for every session on that follower.

The QuorumPeer/Learner/AcceptThread/NIO layers are still alive, so:
- TCP connections are still accepted;
- session revalidation via the leader still succeeds (`Learner@115 Revalidating client…`, `ZooKeeperServer@619 Established session…` — seen at log lines 1893-1917, well after the CommitProcessor is dead);
- but the very next real operation from any client is dropped on the floor at `CommitProcessor.processRequest`, no reply is ever sent, and the client sees `ConnectionLoss` when its read timeout expires — exactly the symptom described.

### One-line summary of the fault

`OpCode.createExt` (opcode 15, used by the `create(...,Stat)` overload) is omitted from `FollowerRequestProcessor.run`'s forward-to-leader switch (`FollowerRequestProcessor.java:84-92`) and from `CommitProcessor.needCommit` (`CommitProcessor.java:131-148`), yet it *is* listed in `Request.isQuorum` (`Request.java:169-170`); the resulting mismatched dispatch pushes a header-less request into `FinalRequestProcessor.processRequest` line 126-128, which dereferences the null `TxnHeader` at `ZKDatabase.java:251`, and the exception triggers `CommitProcessor$CommitWorkRequest.cleanup` → `CommitProcessor.halt` (`CommitProcessor.java:284-290, 346-353`), permanently disabling every client on that follower.
