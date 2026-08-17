# Symptom

A consistency check of the cluster reports that one of `usertable`'s regions is unaccounted
for:

```
ERROR: Region hdfs://localhost:35027/user/root/usertable/ac6a4798d6ab5e1826f038e6a5567a16 has a directory on HDFS with no catalog row, and no region server is serving it.
ERROR: Consistency check failed for table usertable
```

The log for this run is `logs/symptom.log`.
