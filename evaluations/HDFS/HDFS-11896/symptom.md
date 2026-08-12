# symptom.md

The HDFS NameNode's reported cluster **other-used space** metric (`getOtherUsedSpace`, read
via JMX / the admin report) is inflated: it reads about **3 MB** when it should read about
**2 MB**.

The full DEBUG log captured for the run in which this was observed is `logs/symptom.log`.
