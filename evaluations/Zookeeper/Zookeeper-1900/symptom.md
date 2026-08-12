One member of the ZooKeeper ensemble is not serving client requests. Its log for this run,
`logs/symptom.log`, repeats the following thousands of times (first at line 244231):

```
2026-08-12 18:09:33,394 [myid:4] - WARN  [QuorumPeer[myid=4]/0:0:0:0:0:0:0:0:24614:QuorumPeer@963] - Unexpected exception
java.lang.NullPointerException
	at org.apache.zookeeper.server.persistence.FileTxnLog.rollBack(FileTxnLog.java:381)
	at org.apache.zookeeper.server.persistence.FileTxnSnapLog.rollBackLog(FileTxnSnapLog.java:317)
	at org.apache.zookeeper.server.ZKDatabase.rollBackLog(ZKDatabase.java:504)
	at org.apache.zookeeper.server.quorum.Learner.syncWithLeader(Learner.java:348)
	at org.apache.zookeeper.server.quorum.Observer.observeLeader(Observer.java:79)
	at org.apache.zookeeper.server.quorum.QuorumPeer.run(QuorumPeer.java:961)
```
