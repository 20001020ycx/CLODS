/**
 * Reproduction harness for HDFS-11896 ("Non-dfsUsed doubled on dead node
 * re-registration"), branch-2.7 pre-fix tree. This is NOT part of the
 * production source under diagnosis; it only drives a MiniDFSCluster to make
 * the symptom observable and prints it to stdout. DataNode heartbeats are
 * toggled via reflection so no production source is edited.
 */
package org.apache.hadoop.hdfs.server.namenode;

import static org.junit.Assert.assertEquals;

import java.lang.reflect.Method;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hdfs.DFSConfigKeys;
import org.apache.hadoop.hdfs.HdfsConfiguration;
import org.apache.hadoop.hdfs.MiniDFSCluster;
import org.apache.hadoop.hdfs.server.blockmanagement.DatanodeDescriptor;
import org.apache.hadoop.hdfs.server.datanode.DataNode;
import org.apache.hadoop.test.GenericTestUtils;

import com.google.common.base.Supplier;
import org.junit.Test;

public class TestReReg11896 {

  private static void setHeartbeatsDisabled(DataNode dn, boolean v)
      throws Exception {
    Method m = DataNode.class.getDeclaredMethod(
        "setHeartbeatsDisabledForTests", boolean.class);
    m.setAccessible(true);
    m.invoke(dn, v);
  }

  @Test
  public void reproduce() throws Exception {
    Configuration conf = new HdfsConfiguration();
    conf.setInt(DFSConfigKeys.DFS_HEARTBEAT_INTERVAL_KEY, 1);
    conf.setInt(DFSConfigKeys.DFS_NAMENODE_HEARTBEAT_RECHECK_INTERVAL_KEY, 1);
    conf.setInt(DFSConfigKeys.DFS_NAMENODE_STALE_DATANODE_INTERVAL_KEY, 6 * 1000);
    final long CAPACITY = 5000L;
    long[] capacities = new long[] { 4 * CAPACITY, 4 * CAPACITY };
    MiniDFSCluster cluster = null;
    try {
      cluster = new MiniDFSCluster.Builder(conf).numDataNodes(2)
          .simulatedCapacities(capacities).build();
      cluster.waitActive();
      final FSNamesystem ns = cluster.getNamesystem(0);
      final long initialCapacity = ns.getCapacityTotal();

      DataNode dn1 = cluster.getDataNodes().get(0);
      DataNode dn2 = cluster.getDataNodes().get(1);
      final DatanodeDescriptor dn2Desc = NameNodeAdapter.getDatanode(
          ns, dn2.getDatanodeId());
      final DatanodeDescriptor dn1Desc = NameNodeAdapter.getDatanode(
          ns, dn1.getDatanodeId());

      System.out.println("PROBE alive:  cluster_nonDfsUsed="
          + ns.getNonDfsUsedSpace() + " dn1=" + dn1Desc.getNonDfsUsed()
          + " dn2=" + dn2Desc.getNonDfsUsed());

      // Make dn1 miss heartbeats so the NameNode marks it dead (this triggers
      // removeDeadDatanode -> BlockManager.removeBlocksAssociatedTo ->
      // DatanodeDescriptor.resetBlocks()).
      setHeartbeatsDisabled(dn1, true);
      cluster.setDataNodeDead(dn1.getDatanodeId());
      System.out.println("PROBE dead:   cluster_nonDfsUsed="
          + ns.getNonDfsUsedSpace() + " expected(dn2 only)="
          + dn2Desc.getNonDfsUsed() + " capacityTotal=" + ns.getCapacityTotal());

      // Resume heartbeats -> dn1 re-registers and heartbeats again.
      setHeartbeatsDisabled(dn1, false);
      GenericTestUtils.waitFor(new Supplier<Boolean>() {
        @Override public Boolean get() {
          return ns.getCapacityTotal() == initialCapacity
              && ns.getNumLiveDataNodes() == 2;
        }
      }, 100, 10000);
      // Let a couple of real heartbeats settle.
      Thread.sleep(1500);

      long expected = dn1Desc.getNonDfsUsed() + dn2Desc.getNonDfsUsed();
      long observed = ns.getNonDfsUsedSpace();
      System.out.println("PROBE rereg:  cluster_nonDfsUsed=" + observed
          + " expected(dn1+dn2)=" + expected
          + " dn1=" + dn1Desc.getNonDfsUsed()
          + " dn2=" + dn2Desc.getNonDfsUsed()
          + " capacityTotal=" + ns.getCapacityTotal());

      if (observed != expected) {
        System.out.println("SYMPTOM: cluster non-DFS-used space is WRONG after "
            + "dead-node re-registration: observed=" + observed
            + " expected=" + expected + " ratio="
            + ((double) observed / (double) Math.max(1, expected)));
      }
      System.out.println("REPRO_RESULT="
          + (observed != expected ? "BUG_REPRODUCED" : "NO_BUG"));
      assertEquals("cluster non-DFS-used must equal sum of live datanodes",
          expected, observed);
    } finally {
      if (cluster != null) {
        cluster.shutdown();
      }
    }
  }
}
