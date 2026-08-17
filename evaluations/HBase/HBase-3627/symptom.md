# Symptom

The region servers of this HBase cluster repeatedly fail to bring regions online.

The log for this run is `logs/symptom.log`, where a region server reports:

```
ERROR [RS_REGION_BRINGUP-hbase-node-a,60021,1786971731434-0] executor.TaskHandler: Handler died on an unexpected error, task M_RS_BRINGUP_REGION
java.lang.NullPointerException
	at org.apache.hadoop.hbase.util.SerdeUtil.getWritable(SerdeUtil.java:75)
	at org.apache.hadoop.hbase.executor.RegionStateRecord.fromBytes(RegionStateRecord.java:198)
	at org.apache.hadoop.hbase.zookeeper.RegionStateZK.transitionNode(RegionStateZK.java:673)
	at org.apache.hadoop.hbase.zookeeper.RegionStateZK.transitionNodeOpening(RegionStateZK.java:552)
	at org.apache.hadoop.hbase.zookeeper.RegionStateZK.transitionNodeOpening(RegionStateZK.java:545)
	at org.apache.hadoop.hbase.regionserver.handler.RegionBringupHandler.transitionZookeeperOfflineToOpening(RegionBringupHandler.java:297)
	at org.apache.hadoop.hbase.regionserver.handler.RegionBringupHandler.process(RegionBringupHandler.java:90)
	at org.apache.hadoop.hbase.executor.TaskHandler.run(TaskHandler.java:151)
	at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1149)
	at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:624)
	at java.lang.Thread.run(Thread.java:750)
```
