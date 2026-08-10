package com.acme.cluster.usage;

/**
 * Cluster-wide state exposed to operators (dashboard / metrics endpoint).
 * The auxiliary-used-space metric is read straight from the liveness tracker's
 * running totals.
 */
public class ClusterState {
  private final LivenessTracker livenessTracker;

  public ClusterState(LivenessTracker livenessTracker) {
    this.livenessTracker = livenessTracker;
  }

  /** Total auxiliary-used space across all live nodes (dashboard metric). */
  public long getAuxUsedSpace() {
    return livenessTracker.getAuxUsedTotal();
  }
}
