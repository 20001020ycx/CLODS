package com.acme.cluster.usage;

/**
 * Server-side view of a single volume on a node. Updated from the node's
 * heartbeat {@link UsageReport}s; can re-emit its last-known report.
 */
public class VolumeUsage {
  private final VolumeId volume;
  private long capacity;
  private long primaryUsed;
  private long remaining;
  private long poolUsed;
  private long auxUsed;

  public VolumeUsage(VolumeId volume) {
    this.volume = volume;
  }

  public VolumeId getVolume() { return volume; }

  /** Absorb a fresh usage report for this volume. */
  void receivedHeartbeat(UsageReport r) {
    this.capacity = r.getCapacity();
    this.primaryUsed = r.getPrimaryUsed();
    this.remaining = r.getRemaining();
    this.poolUsed = r.getPoolUsed();
    this.auxUsed = r.getAuxUsed();
  }

  /** Re-emit this volume's last-known usage as a report. */
  UsageReport toReport() {
    return new UsageReport(volume, capacity, primaryUsed, remaining,
        poolUsed, auxUsed);
  }

  long getAuxUsed() { return auxUsed; }
}
