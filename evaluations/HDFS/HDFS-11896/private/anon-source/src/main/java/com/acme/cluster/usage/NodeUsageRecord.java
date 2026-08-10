package com.acme.cluster.usage;

import java.util.HashMap;
import java.util.Map;

/**
 * The registry's live record for one node: the node-level usage totals plus
 * the per-volume views, and the lifecycle flags used by {@link LivenessTracker}.
 *
 * The node-level totals are recomputed from the node's volume reports on every
 * heartbeat (see {@link #applyUsageReport}). When a node is removed from the
 * registry, its record is cleared via {@link #clearNodeState()}.
 */
public class NodeUsageRecord extends NodeUsageBase {
  private static final Log LOG = Log.getLog(NodeUsageRecord.class);

  /** Whether the tracker currently considers this node alive. */
  boolean alive = false;

  /** Set once the node has sent a real heartbeat after (re-)registering. */
  private boolean heartbeatedSinceRegistration = false;

  private final Map<VolumeId, VolumeUsage> volumeMap = new HashMap<>();

  public NodeUsageRecord(String nodeId) { super(nodeId); }

  public boolean isHeartbeatedSinceRegistration() {
    return heartbeatedSinceRegistration;
  }

  private VolumeUsage updateVolume(VolumeId id) {
    VolumeUsage v = volumeMap.get(id);
    if (v == null) {
      v = new VolumeUsage(id);
      volumeMap.put(id, v);
    }
    return v;
  }

  /** Re-emit the node's current per-volume usage as reports. */
  UsageReport[] getReports() {
    UsageReport[] out = new UsageReport[volumeMap.size()];
    int i = 0;
    for (VolumeUsage v : volumeMap.values()) {
      out[i++] = v.toReport();
    }
    return out;
  }

  /**
   * Reset this node's accounting when it leaves the registry, so a stale node
   * contributes nothing to the cluster totals.
   */
  public void clearNodeState() {
    setCapacity(0);
    setRemaining(0);
    setPoolUsed(0);
    setPrimaryUsed(0);
    setXceiverCount(0);
  }

  /** Handle a heartbeat: refresh totals, then mark the node as heartbeated. */
  public void onHeartbeat(UsageReport[] reports, long cacheCapacity,
      long cacheUsed, int xceiverCount) {
    applyUsageReport(reports, cacheCapacity, cacheUsed, xceiverCount);
    heartbeatedSinceRegistration = true;
  }

  /**
   * Recompute the node-level totals from the given per-volume reports.
   * Called on every heartbeat, and on (re-)registration with an empty report
   * array to zero the node until its first real heartbeat arrives.
   */
  public void applyUsageReport(UsageReport[] reports, long cacheCapacity,
      long cacheUsed, int xceiverCount) {
    long totalCapacity = 0;
    long totalRemaining = 0;
    long totalPoolUsed = 0;
    long totalPrimaryUsed = 0;
    long totalAuxUsed = 0;

    setCacheCapacity(cacheCapacity);
    setCacheUsed(cacheUsed);
    setXceiverCount(xceiverCount);

    for (UsageReport report : reports) {
      VolumeUsage volume = updateVolume(report.getVolume());
      volume.receivedHeartbeat(report);
      totalCapacity += report.getCapacity();
      totalRemaining += report.getRemaining();
      totalPoolUsed += report.getPoolUsed();
      totalPrimaryUsed += report.getPrimaryUsed();
      totalAuxUsed += report.getAuxUsed();
    }

    // Update total metrics for the node.
    setCapacity(totalCapacity);
    setRemaining(totalRemaining);
    setPoolUsed(totalPoolUsed);
    setPrimaryUsed(totalPrimaryUsed);
    setAuxUsed(totalAuxUsed);
  }
}
