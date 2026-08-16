Client calls against this ZooKeeper 3.5.0 ensemble stop completing and fail with
`KeeperException.ConnectionLoss`. The log for this run is `logs/symptom.log`, where the
affected sessions report:

```
[myid:] - INFO  [main-SendThread(127.0.0.1:24551):ClientCnxn$SendThread@1207] - Session inactive - no server traffic for 6666ms for sessionid 0x1a008cd5e440000, closing socket connection and attempting reconnect
```
