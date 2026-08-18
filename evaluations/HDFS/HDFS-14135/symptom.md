# symptom.md

A WebHDFS client operation against the NameNode HTTP endpoint fails, and the run reports:

```
java.lang.AssertionError:  Expected to find 'localhost:40019: connect timed out' but got unexpected exception: java.net.SocketTimeoutException: localhost:40019: Read timed out
```

The log for this run is `logs/symptom.log`.
