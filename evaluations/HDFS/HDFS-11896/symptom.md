# symptom.md — bug (cluster usage accounting)

A distributed service keeps a cluster-wide "auxiliary-used space" metric that
should equal the sum of the auxiliary-used space reported by every currently
live node. Under normal operation the metric is correct.

However, when a node stops sending heartbeats and is declared **expired** (removed
from the live set), and then later comes back and **re-registers** and resumes
heartbeating, the cluster-wide auxiliary-used metric ends up **too high**: the
returning node's auxiliary-used space is counted **twice**. With two nodes each
reporting 5000, the metric reads 15000 after one node re-registers, instead of the
correct 10000. No error or exception is logged — only the metric value is wrong,
and it stays wrong.

This is the failure to diagnose. Do not assume anything about the system or any
known fix.
