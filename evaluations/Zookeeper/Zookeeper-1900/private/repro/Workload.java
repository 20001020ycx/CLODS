import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import org.apache.zookeeper.CreateMode;
import org.apache.zookeeper.KeeperException;
import org.apache.zookeeper.WatchedEvent;
import org.apache.zookeeper.Watcher;
import org.apache.zookeeper.ZooDefs.Ids;
import org.apache.zookeeper.ZooKeeper;
import org.apache.zookeeper.data.Stat;

/**
 * An ordinary ZooKeeper client used to drive real traffic at the cluster during
 * reproduction. It is deliberately dumb: it only calls the public client API.
 *
 * It NEVER writes to stdout/stderr — everything it observes goes into the result file
 * named by the last argument, which reproduce.sh reads for its assertions. The only
 * thing that reaches this process's stdout is the ZooKeeper client library's own log4j
 * output, which is what gets collected into the symptom log.
 *
 * usage: Workload <connectString> <rootPath> <n> <mode> <resultFile>
 *   mode=normal     : a plain read/write workload (create/getData/setData/exists/
 *                     getChildren/delete), all through the ordinary API, <n> iterations.
 *   mode=collateral : keeps issuing ordinary ops for <n> seconds and counts how many
 *                     succeed — used to observe other clients on the same server.
 *   mode=probe      : tries to establish one ordinary session and do one create/get/delete
 *                     against whatever server it was pointed at, then reports what happened.
 *                     Used to see whether a given member can serve clients at all.
 */
public class Workload {

    public static void main(String[] args) throws Exception {
        String connect = args[0];
        String root = args[1];
        int n = Integer.parseInt(args[2]);
        String mode = args[3];
        PrintWriter res = new PrintWriter(new FileWriter(args[4]), true);

        int sessionTimeout = "probe".equals(mode) ? 8000 : 10000;
        final CountDownLatch connected = new CountDownLatch(1);
        ZooKeeper zk = new ZooKeeper(connect, sessionTimeout, new Watcher() {
            public void process(WatchedEvent event) {
                if (event.getState() == Event.KeeperState.SyncConnected) {
                    connected.countDown();
                }
            }
        });
        long t0 = System.currentTimeMillis();
        boolean up = connected.await("probe".equals(mode) ? 20 : 30, TimeUnit.SECONDS);
        if (!up) {
            res.println("connect=TIMEOUT connectString=" + connect
                    + " waited_ms=" + (System.currentTimeMillis() - t0)
                    + " state=" + zk.getState());
            res.println("final_state=" + zk.getState());
            res.close();
            try {
                zk.close();
            } catch (Throwable ignored) {
                // nothing to do — the server never answered
            }
            System.exit(2);
        }
        res.println("connect=OK connectString=" + connect
                + " elapsed_ms=" + (System.currentTimeMillis() - t0));

        try {
            mkRoot(zk, root);
            if ("normal".equals(mode)) {
                normal(zk, root, n, res);
            } else if ("collateral".equals(mode)) {
                collateral(zk, root, n, res);
            } else if ("probe".equals(mode)) {
                probe(zk, root, res);
            } else {
                res.println("mode=UNKNOWN");
            }
        } catch (Throwable t) {
            res.println("workload=ABORTED " + t.getClass().getName() + ": " + t.getMessage());
        } finally {
            res.println("final_state=" + zk.getState());
            res.close();
            try {
                zk.close();
            } catch (Throwable ignored) {
                // a dead server can leave close() hanging; the shell wraps us in `timeout`
            }
        }
    }

    private static void mkRoot(ZooKeeper zk, String root) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (String part : root.split("/")) {
            if (part.isEmpty()) {
                continue;
            }
            sb.append('/').append(part);
            try {
                zk.create(sb.toString(), new byte[0], Ids.OPEN_ACL_UNSAFE, CreateMode.PERSISTENT);
            } catch (KeeperException.NodeExistsException e) {
                // fine, another session created it
            }
        }
    }

    /** Ordinary mixed read/write traffic. */
    private static void normal(ZooKeeper zk, String root, int n, PrintWriter res) throws Exception {
        int ok = 0, failed = 0;
        for (int i = 0; i < n; i++) {
            String p = root + "/n" + i;
            try {
                zk.create(p, ("payload-" + i).getBytes(), Ids.OPEN_ACL_UNSAFE, CreateMode.PERSISTENT);
                zk.getData(p, false, new Stat());
                zk.setData(p, ("payload-" + i + "-v2").getBytes(), -1);
                zk.exists(p, false);
                if (i % 5 == 0) {
                    zk.getChildren(root, false);
                }
                if (i % 3 == 0) {
                    zk.delete(p, -1);
                }
                ok++;
            } catch (Exception e) {
                failed++;
                if (failed <= 5) {
                    res.println("op_failed i=" + i + " " + e.getClass().getName() + ": " + e.getMessage());
                }
            }
        }
        res.println("normal_ok=" + ok + " normal_failed=" + failed);
    }

    /** Another client on the same server, doing ordinary work for <seconds> seconds. */
    private static void collateral(ZooKeeper zk, String root, int seconds, PrintWriter res)
            throws Exception {
        int ok = 0, failed = 0;
        long deadline = System.currentTimeMillis() + seconds * 1000L;
        int i = 0;
        while (System.currentTimeMillis() < deadline) {
            String p = root + "/c" + (i++);
            try {
                zk.create(p, ("c" + i).getBytes(), Ids.OPEN_ACL_UNSAFE, CreateMode.EPHEMERAL);
                zk.getData(p, false, new Stat());
                zk.delete(p, -1);
                ok++;
            } catch (Exception e) {
                failed++;
                if (failed <= 5) {
                    res.println("collateral_failed i=" + i + " " + e.getClass().getName() + ": "
                            + e.getMessage());
                }
            }
            Thread.sleep(200);
        }
        res.println("collateral_ok=" + ok + " collateral_failed=" + failed);
    }

    /** One ordinary session against one specific member: can it serve a client at all? */
    private static void probe(ZooKeeper zk, String root, PrintWriter res) {
        String p = root + "/probe-" + System.nanoTime();
        long t0 = System.currentTimeMillis();
        try {
            zk.create(p, "probe".getBytes(), Ids.OPEN_ACL_UNSAFE, CreateMode.EPHEMERAL);
            zk.getData(p, false, new Stat());
            zk.delete(p, -1);
            res.println("probe=OK elapsed_ms=" + (System.currentTimeMillis() - t0));
        } catch (Throwable e) {
            res.println("probe=EXCEPTION " + e.getClass().getName() + ": " + e.getMessage()
                    + " elapsed_ms=" + (System.currentTimeMillis() - t0));
        }
    }
}
