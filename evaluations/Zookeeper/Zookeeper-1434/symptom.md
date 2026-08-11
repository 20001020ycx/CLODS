During an ordinary interactive ZooKeeper command-line shell (zkCli) session against a
healthy standalone server, the shell process dies with an unhandled
`java.lang.NullPointerException` (JVM exit code 1) as soon as the operator asks for node
metadata with the `meta` command on a znode path that does not exist. The server answers
the request normally; it is the client shell that terminates at the prompt, so the rest of
the session is lost. The same command against znodes that do exist prints their metadata
without any problem.
