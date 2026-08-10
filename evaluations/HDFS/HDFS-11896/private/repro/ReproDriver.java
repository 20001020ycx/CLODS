import com.acme.cluster.usage.*;

/**
 * Anonymized reproduction driver for the doubling bug (analog of the real
 * MiniDFSCluster scenario). NOT part of source/ under diagnosis; it only drives
 * the accounting components and prints the observed cluster metric. Its stdout
 * is captured as logs/symptom.log.
 */
public class ReproDriver {
  public static void main(String[] a) {
    LivenessTracker lt = new LivenessTracker();
    ShardManager sm = new ShardManager();
    NodeRegistry reg = new NodeRegistry(lt, sm);
    ClusterState cluster = new ClusterState(lt);

    NodeUsageRecord n1 = new NodeUsageRecord("node-1");
    NodeUsageRecord n2 = new NodeUsageRecord("node-2");
    UsageReport[] r1 = { new UsageReport(new VolumeId("vol-1"), 20000, 0, 20000, 0, 5000) };
    UsageReport[] r2 = { new UsageReport(new VolumeId("vol-2"), 20000, 0, 20000, 0, 5000) };

    // Initial registration + first heartbeat for both nodes.
    reg.registerNode(n1);
    reg.registerNode(n2);
    reg.onHeartbeat(n1, r1, 0, 0, 0);
    reg.onHeartbeat(n2, r2, 0, 0, 0);
    System.out.println("PROBE alive:   cluster_auxUsed=" + cluster.getAuxUsedSpace()
        + " n1=" + n1.getAuxUsed() + " n2=" + n2.getAuxUsed());

    // node-1 stops heartbeating and is declared expired.
    reg.removeExpiredNode(n1);
    System.out.println("PROBE expired: cluster_auxUsed=" + cluster.getAuxUsedSpace()
        + " expected(n2 only)=" + n2.getAuxUsed());

    // node-1 comes back: re-registration, then a real heartbeat.
    reg.registerNode(n1);
    reg.onHeartbeat(n1, r1, 0, 0, 0);

    long expected = n1.getAuxUsed() + n2.getAuxUsed();
    long observed = cluster.getAuxUsedSpace();
    System.out.println("PROBE rereg:   cluster_auxUsed=" + observed
        + " expected(n1+n2)=" + expected
        + " n1=" + n1.getAuxUsed() + " n2=" + n2.getAuxUsed());
    if (observed != expected) {
      System.out.println("SYMPTOM: cluster auxiliary-used space is WRONG after node "
          + "re-registration: observed=" + observed + " expected=" + expected
          + " ratio=" + ((double) observed / (double) Math.max(1, expected)));
    }
    System.out.println("REPRO_RESULT=" + (observed != expected ? "BUG_REPRODUCED" : "NO_BUG"));
  }
}
