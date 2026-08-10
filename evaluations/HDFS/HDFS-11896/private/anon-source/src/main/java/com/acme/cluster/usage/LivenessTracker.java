package com.acme.cluster.usage;

import java.util.HashSet;
import java.util.Set;

/**
 * Tracks which nodes are alive and maintains the cluster-wide usage totals.
 *
 * The totals are kept incrementally: {@link Stats#add} is applied when a node
 * joins the live set, {@link Stats#subtract} when it leaves, and a heartbeat is
 * a subtract-then-add so the node's latest numbers replace its previous ones.
 */
public class LivenessTracker {

  private final Set<NodeUsageRecord> nodes = new HashSet<>();
  private final Stats stats = new Stats();

  /** Cluster-wide auxiliary-used total exposed on the dashboard. */
  public synchronized long getAuxUsedTotal() {
    return stats.auxUsedTotal;
  }

  /** Treat a (re-)registration as the node joining the live set. */
  synchronized void register(final NodeUsageRecord d) {
    if (!d.alive) {
      addNode(d);

      // reset its counters until the first real heartbeat arrives
      d.applyUsageReport(UsageReport.EMPTY_ARRAY, 0L, 0L, 0);
    }
  }

  synchronized void addNode(final NodeUsageRecord d) {
    stats.add(d);
    nodes.add(d);
    d.alive = true;
  }

  synchronized void dropNode(final NodeUsageRecord node) {
    if (node.alive) {
      stats.subtract(node);
      nodes.remove(node);
      node.alive = false;
    }
  }

  /** Process a heartbeat: replace the node's contribution to the totals. */
  synchronized void onHeartbeat(final NodeUsageRecord node,
      UsageReport[] reports, long cacheCapacity, long cacheUsed,
      int xceiverCount) {
    stats.subtract(node);
    node.onHeartbeat(reports, cacheCapacity, cacheUsed, xceiverCount);
    stats.add(node);
  }

  /** Incrementally-maintained cluster usage totals. */
  private static class Stats {
    private long capacityTotal = 0L;
    private long capacityUsed = 0L;
    private long auxUsedTotal = 0L;
    private long capacityRemaining = 0L;
    private long poolUsed = 0L;
    private int  xceiverCount = 0;
    private long cacheCapacity = 0L;
    private long cacheUsed = 0L;

    private void add(final NodeUsageRecord node) {
      capacityUsed += node.getPrimaryUsed();
      auxUsedTotal += node.getAuxUsed();
      poolUsed += node.getPoolUsed();
      xceiverCount += node.getXceiverCount();
      capacityTotal += node.getCapacity();
      capacityRemaining += node.getRemaining();
      cacheCapacity += node.getCacheCapacity();
      cacheUsed += node.getCacheUsed();
    }

    private void subtract(final NodeUsageRecord node) {
      capacityUsed -= node.getPrimaryUsed();
      auxUsedTotal -= node.getAuxUsed();
      poolUsed -= node.getPoolUsed();
      xceiverCount -= node.getXceiverCount();
      capacityTotal -= node.getCapacity();
      capacityRemaining -= node.getRemaining();
      cacheCapacity -= node.getCacheCapacity();
      cacheUsed -= node.getCacheUsed();
    }
  }
}
