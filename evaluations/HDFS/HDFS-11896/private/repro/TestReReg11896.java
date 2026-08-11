/**
 * Reproduction harness for HDFS-11896 ("Non-dfsUsed doubled on dead node
 * re-registration"), branch-2.7 pre-fix tree.
 *
 * Integrity rules (METHODOLOGY.md M3):
 *   - Verbose (DEBUG) logging is turned on so the captured log is a rich, real trace.
 *   - The cluster is exercised with normal operations (file writes + reads) before the
 *     dead -> re-register cycle, so the log reflects genuine activity.
 *   - NO print/log statements are added anywhere. The bug is detected purely by a JUnit
 *     assertion on the NameNode's own metric (assertion output goes to the test runner,
 *     never into the captured symptom log). DataNode heartbeats are toggled via reflection
 *     so no production source is edited.
 */
package org.apache.hadoop.hdfs.server.namenode;

import static org.junit.Assert.assertEquals;

import java.lang.reflect.Method;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hdfs.DFSConfigKeys;
import org.apache.hadoop.hdfs.DFSTestUtil;
import org.apache.hadoop.hdfs.HdfsConfiguration;
import org.apache.hadoop.hdfs.MiniDFSCluster;
import org.apache.hadoop.hdfs.server.blockmanagement.DatanodeDescriptor;
import org.apache.hadoop.hdfs.server.datanode.DataNode;
import org.apache.hadoop.test.GenericTestUtils;

import com.google.common.base.Supplier;
import org.apache.log4j.Level;
import org.apache.log4j.Logger;
import org.junit.Test;

public class TestReReg11896 {

  private static void verbose() {
    // Turn the failure-path subsystems up to DEBUG so the captured log is realistic.
    for (String n : new String[] {
        "org.apache.hadoop.hdfs.server.blockmanagement",
        "org.apache.hadoop.hdfs.server.datanode",
        "org.apache.hadoop.hdfs.server.namenode",
        "org.apache.hadoop.hdfs.StateChange",
        "BlockStateChange" }) {
      Logger.getLogger(n).setLevel(Level.DEBUG);
    }
  }

  private static void setHeartbeatsDisabled(DataNode dn, boolean v)
      throws Exception {
    Method m = DataNode.class.getDeclaredMethod(
        "setHeartbeatsDisabledForTests", boolean.class);
    m.setAccessible(true);
    m.invoke(dn, v);
  }

  @Test
  public void reproduce() throws Exception {
    verbose();
    Configuration conf = new HdfsConfiguration();
    conf.setInt(DFSConfigKeys.DFS_HEARTBEAT_INTERVAL_KEY, 1);
    conf.setInt(DFSConfigKeys.DFS_NAMENODE_HEARTBEAT_RECHECK_INTERVAL_KEY, 1);
    conf.setInt(DFSConfigKeys.DFS_NAMENODE_STALE_DATANODE_INTERVAL_KEY, 6 * 1000);
    final long CAPACITY = 1L << 20; // 1 MB per unit -> 4 MB per node (fits small blocks)
    long[] capacities = new long[] { 4 * CAPACITY, 4 * CAPACITY };
    MiniDFSCluster cluster = null;
    try {
      cluster = new MiniDFSCluster.Builder(conf).numDataNodes(2)
          .simulatedCapacities(capacities).build();
      cluster.waitActive();
      final FSNamesystem ns = cluster.getNamesystem(0);

      // ---- normal operations: write a few files and read them back ----
      FileSystem fs = cluster.getFileSystem();
      for (int i = 0; i < 3; i++) {
        Path p = new Path("/user/app/data-" + i + ".bin");
        // small block size so blocks fit the simulated volumes
        DFSTestUtil.createFile(fs, p, 4096, 64 * 1024, 4096, (short) 2, 0xC0FFEE + i);
        DFSTestUtil.readFileBuffer(fs, p);
      }

      DataNode dn1 = cluster.getDataNodes().get(0);
      DataNode dn2 = cluster.getDataNodes().get(1);
      final DatanodeDescriptor dn2Desc = NameNodeAdapter.getDatanode(
          ns, dn2.getDatanodeId());
      final DatanodeDescriptor dn1Desc = NameNodeAdapter.getDatanode(
          ns, dn1.getDatanodeId());

      // ---- dn1 stops heartbeating and is declared dead ----
      setHeartbeatsDisabled(dn1, true);
      cluster.setDataNodeDead(dn1.getDatanodeId());

      // ---- dn1 comes back: re-registers and heartbeats again ----
      setHeartbeatsDisabled(dn1, false);
      final long initialCapacity = 2L * (4 * CAPACITY);
      GenericTestUtils.waitFor(new Supplier<Boolean>() {
        @Override public Boolean get() {
          return ns.getCapacityTotal() == initialCapacity
              && ns.getNumLiveDataNodes() == 2;
        }
      }, 100, 10000);
      Thread.sleep(1500); // let a couple of real heartbeats settle

      // Detection is a silent assertion (no logging): the NameNode's own metric
      // must equal the sum over live nodes. On the buggy tree it is doubled.
      long expected = dn1Desc.getNonDfsUsed() + dn2Desc.getNonDfsUsed();
      long observed = ns.getNonDfsUsedSpace();
      assertEquals("cluster non-DFS-used must equal sum of live datanodes",
          expected, observed);
    } finally {
      if (cluster != null) {
        cluster.shutdown();
      }
    }
  }
}
