# symptom.md

On an HDFS cluster, the NameNode's reported cluster **other-used space** metric
(`CapacityUsedOther`, exposed via JMX / the metrics system) reads an abnormally high value —
it is inflated well beyond the actual non-service disk usage across the datanodes.

The NameNode log for the affected period is `logs/symptom.log`; the `CapacityUsedOther`
metric samples appear in it.
