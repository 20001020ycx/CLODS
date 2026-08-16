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
 * usage: Workload <connectString> <rootPath> <ops> <mode> <resultFile>
 *   mode=normal     : a plain read/write workload (create/getData/setData/exists/
 *                     getChildren/delete), all through the ordinary API.
 *   mode=createstat : a few plain ops, then ONE create that asks the server to return
 *                     the new node's Stat (the create(path,data,acl,mode,Stat) overload),
 *                     then one more op to see whether the session survived.
 *   mode=collateral : keeps issuing ordinary ops for <ops> seconds and counts how many
 *                     succeed — used to observe other clients on the same server.
 */
public class Workload {

    public static void main(String[] args) throws Exception {
        String connect = args[0];
        String root = args[1];
        int n = Integer.parseInt(args[2]);
        String mode = args[3];
        PrintWriter res = new PrintWriter(new FileWriter(args[4]), true);

        final CountDownLatch connected = new CountDownLatch(1);
        ZooKeeper zk = new ZooKeeper(connect, 10000, new Watcher() {
            public void process(WatchedEvent event) {
                if (event.getState() == Event.KeeperState.SyncConnected) {
                    connected.countDown();
                }
            }
        });
        if (!connected.await(30, TimeUnit.SECONDS)) {
            res.println("connect=TIMEOUT");
            res.close();
            System.exit(2);
        }
        res.println("connect=OK connectString=" + connect);

        try {
            mkRoot(zk, root);
            if ("normal".equals(mode)) {
                normal(zk, root, n, res);
            } else if ("createstat".equals(mode)) {
                createStat(zk, root, res);
            } else if ("collateral".equals(mode)) {
                collateral(zk, root, n, res);
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
                res.println("op_failed i=" + i + " " + e.getClass().getName() + ": " + e.getMessage());
            }
        }
        res.println("normal_ok=" + ok + " normal_failed=" + failed);
    }

    /**
     * The interesting session: prove the connection works with a plain create, then do
     * the same create but ask for the resulting Stat back.
     */
    private static void createStat(ZooKeeper zk, String root, PrintWriter res) throws Exception {
        String control = root + "/entry-" + System.nanoTime();
        long t0 = System.currentTimeMillis();
        try {
            zk.create(control, "entry".getBytes(), Ids.OPEN_ACL_UNSAFE, CreateMode.PERSISTENT);
            res.println("plain_create=OK elapsed_ms=" + (System.currentTimeMillis() - t0));
        } catch (Exception e) {
            res.println("plain_create=EXCEPTION " + e.getClass().getName() + ": " + e.getMessage());
        }

        String target = root + "/item-9137";
        Stat stat = new Stat();
        t0 = System.currentTimeMillis();
        try {
            String created = zk.create(target, "item".getBytes(), Ids.OPEN_ACL_UNSAFE,
                    CreateMode.PERSISTENT, stat);
            res.println("create_with_stat=OK path=" + created + " czxid=" + stat.getCzxid()
                    + " elapsed_ms=" + (System.currentTimeMillis() - t0));
        } catch (Throwable e) {
            res.println("create_with_stat=EXCEPTION " + e.getClass().getName() + ": " + e.getMessage()
                    + " elapsed_ms=" + (System.currentTimeMillis() - t0));
        }
        res.println("target_path=" + target);
        res.println("state_after_create_with_stat=" + zk.getState());

        t0 = System.currentTimeMillis();
        try {
            zk.exists(control, false);
            res.println("post_op=OK elapsed_ms=" + (System.currentTimeMillis() - t0));
        } catch (Throwable e) {
            res.println("post_op=EXCEPTION " + e.getClass().getName() + ": " + e.getMessage()
                    + " elapsed_ms=" + (System.currentTimeMillis() - t0));
        }
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
}
