package com.acme.cluster.usage;

/**
 * Node-level aggregate usage counters (summed across the node's volumes).
 * These are the per-node totals the cluster aggregates for its dashboard.
 */
public class NodeUsageBase {
  private final String nodeId;

  private long capacity;
  private long primaryUsed;
  private long auxUsed;
  private long remaining;
  private long poolUsed;
  private int  xceiverCount;
  private long cacheCapacity;
  private long cacheUsed;

  public NodeUsageBase(String nodeId) { this.nodeId = nodeId; }

  public String getNodeId() { return nodeId; }

  public long getCapacity()      { return capacity; }
  public void setCapacity(long v){ this.capacity = v; }

  public long getPrimaryUsed()      { return primaryUsed; }
  public void setPrimaryUsed(long v){ this.primaryUsed = v; }

  public long getAuxUsed()      { return auxUsed; }
  public void setAuxUsed(long v){ this.auxUsed = v; }

  public long getRemaining()      { return remaining; }
  public void setRemaining(long v){ this.remaining = v; }

  public long getPoolUsed()      { return poolUsed; }
  public void setPoolUsed(long v){ this.poolUsed = v; }

  public int  getXceiverCount()      { return xceiverCount; }
  public void setXceiverCount(int v) { this.xceiverCount = v; }

  public long getCacheCapacity()      { return cacheCapacity; }
  public void setCacheCapacity(long v){ this.cacheCapacity = v; }

  public long getCacheUsed()      { return cacheUsed; }
  public void setCacheUsed(long v){ this.cacheUsed = v; }

  @Override public String toString() { return "node[" + nodeId + "]"; }
}
