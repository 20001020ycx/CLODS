package com.acme.cluster.usage;

/**
 * An immutable per-volume usage report sent by a node in each heartbeat.
 *
 * {@code auxUsed} is space consumed on the volume by things other than this
 * service (i.e. capacity - remaining - primaryUsed is not assumed; auxUsed is
 * reported explicitly by the node).
 */
public final class UsageReport {
  public static final UsageReport[] EMPTY_ARRAY = new UsageReport[0];

  private final VolumeId volume;
  private final long capacity;
  private final long primaryUsed;
  private final long remaining;
  private final long poolUsed;
  private final long auxUsed;

  public UsageReport(VolumeId volume, long capacity, long primaryUsed,
      long remaining, long poolUsed, long auxUsed) {
    this.volume = volume;
    this.capacity = capacity;
    this.primaryUsed = primaryUsed;
    this.remaining = remaining;
    this.poolUsed = poolUsed;
    this.auxUsed = auxUsed;
  }

  public VolumeId getVolume()   { return volume; }
  public long getCapacity()     { return capacity; }
  public long getPrimaryUsed()  { return primaryUsed; }
  public long getRemaining()    { return remaining; }
  public long getPoolUsed()     { return poolUsed; }
  public long getAuxUsed()      { return auxUsed; }
}
