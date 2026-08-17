A store file of table `usertable` cannot be read: every time the region is opened, the region
server reports that file and carries on without it.

The log for this run is `logs/symptom.log`, where the report reads:

```
WARN  [RS_OPEN_REGION-301c62b05914,60020,1786994401221-0] org.apache.hadoop.hbase.regionserver.FamilyStore: Cannot read hdfs://localhost:8020/hbase/usertable/0c5dd13f705a47db70c9a7e8e0de5c66/cf/1553916852809385968; leaving it out of this column family's file list. Check the file.
java.io.IOException: java.lang.IllegalArgumentException: Invalid HFile version: 1652127846 (expected to be between 1 and 2)
	at org.apache.hadoop.hbase.io.hfile.FixedFileTrailer.readFromStream(FixedFileTrailer.java:306)
	at org.apache.hadoop.hbase.io.hfile.HFile.pickReaderVersion(HFile.java:330)
	at org.apache.hadoop.hbase.io.hfile.HFile.createReader(HFile.java:346)
	at org.apache.hadoop.hbase.regionserver.StoreFile$Reader.<init>(StoreFile.java:983)
	at org.apache.hadoop.hbase.regionserver.StoreFile.open(StoreFile.java:444)
	at org.apache.hadoop.hbase.regionserver.StoreFile.createReader(StoreFile.java:517)
	at org.apache.hadoop.hbase.regionserver.FamilyStore.openStoreFiles(FamilyStore.java:273)
	at org.apache.hadoop.hbase.regionserver.FamilyStore.<init>(FamilyStore.java:215)
	at org.apache.hadoop.hbase.regionserver.HRegion.instantiateHStore(HRegion.java:2409)
```
