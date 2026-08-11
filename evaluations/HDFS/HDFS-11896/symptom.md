# symptom.md

An HDFS NameNode exposes a cluster-wide **"other-used" space** metric
(`getOtherUsedSpace`, visible via JMX / the admin report). It should equal the sum of the
other-used space reported by every currently live DataNode.

After normal use (some files written and read), a DataNode stops heartbeating and is
declared **dead**, then comes back and **re-registers** and resumes heartbeating. From that
point the NameNode's reported cluster other-used metric is **too high**: it exceeds the true
sum over the live DataNodes by about one node's worth of other-used space (the returning
node's contribution). Concretely, in a two-DataNode cluster the metric reads ~3 MB when the
true total is ~2 MB. Capacity and DFS-used totals remain correct; only the other-used metric
is wrong, no error or exception is logged, and it stays wrong.

The attached log is the NameNode/DataNode DEBUG log captured across this scenario. Identify
the specific lines of code and the exact logical conditions (branches) that dictate this
failure path. Do not assume any known fix.
