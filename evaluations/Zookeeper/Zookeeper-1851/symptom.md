Client calls against this ZooKeeper 3.5.0 ensemble stop completing and fail with
`KeeperException.ConnectionLoss`. The log for this run is `logs/symptom.log`, where the
affected sessions report:

```
2026-08-12 01:41:58,930 [myid:] - INFO  [main-SendThread(127.0.0.1:24551):ClientCnxn$SendThread@1207] - Client session timed out, have not heard from server in 6670ms for sessionid 0x19ff3a1f9800001, closing socket connection and attempting reconnect
```
