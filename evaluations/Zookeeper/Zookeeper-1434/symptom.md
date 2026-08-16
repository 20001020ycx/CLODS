The command-line shell process terminated with the following uncaught exception (JVM exit
code 1), printed at the end of `logs/symptom.log`:

```
Exception in thread "main" java.lang.NullPointerException
	at org.apache.zookeeper.CliShellMain.printNodeMeta(CliShellMain.java:132)
	at org.apache.zookeeper.CliShellMain.processZKCmd(CliShellMain.java:727)
	at org.apache.zookeeper.CliShellMain.processCmd(CliShellMain.java:583)
	at org.apache.zookeeper.CliShellMain.executeLine(CliShellMain.java:355)
	at org.apache.zookeeper.CliShellMain.run(CliShellMain.java:313)
	at org.apache.zookeeper.CliShellMain.main(CliShellMain.java:272)
```
