One member of the ZooKeeper ensemble is not serving client requests. The log for this run is
`logs/symptom.log`, where that member repeatedly reports:

```
[myid:4] - WARN  [EnsembleMember[myid=4]/0:0:0:0:0:0:0:0:24614:EnsembleMember@963] - Unhandled error in the peer state machine
java.lang.NullPointerException
	at org.apache.zookeeper.server.persistence.TxnJournal.rollBack(TxnJournal.java:381)
	at org.apache.zookeeper.server.persistence.JournalSnapStore.rollBackLog(JournalSnapStore.java:317)
	at org.apache.zookeeper.server.ZKStateStore.rollBackLog(ZKStateStore.java:504)
	at org.apache.zookeeper.server.quorum.PeerSynchronizer.syncWithLeader(PeerSynchronizer.java:348)
	at org.apache.zookeeper.server.quorum.ObserverPeer.observeLeader(ObserverPeer.java:79)
	at org.apache.zookeeper.server.quorum.EnsembleMember.run(EnsembleMember.java:961)
```
