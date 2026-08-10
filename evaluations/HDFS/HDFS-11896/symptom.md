# symptom.md

An HDFS NameNode exposes a cluster-wide **"other-used" space** metric
(`getOtherUsedSpace`) that should equal the sum of the other-used space reported by
every currently live DataNode. Under normal operation it is correct.

However, when a DataNode stops heartbeating and is declared **dead** (removed from the
live set), and then comes back and **re-registers** and resumes heartbeating, the
cluster-wide other-used metric ends up **too high**: the returning node's other-used
space is counted **twice**. With two DataNodes each reporting 5000, the metric reads
**15000** after one node re-registers, instead of the correct **10000**. No error or
exception is logged — only the metric value is wrong, and it stays wrong.

Identify the specific lines of code and the exact logical conditions (branches) that
dictate this failure path. Do not assume any known fix.
