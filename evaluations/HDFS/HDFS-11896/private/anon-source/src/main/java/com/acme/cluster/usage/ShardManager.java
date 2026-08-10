package com.acme.cluster.usage;

/**
 * Owns the shard placement map. When a node leaves the cluster, the shards it
 * hosted are released and the node's usage record is cleared.
 */
public class ShardManager {
  private static final Log LOG = Log.getLog(ShardManager.class);

  /**
   * Release all shards hosted on {@code node} and clear its usage record.
   * Invoked when the node is removed from the registry (e.g. after it is
   * declared expired).
   */
  void releaseNodeShards(final NodeUsageRecord node) {
    // ... release each shard hosted on the node (elided) ...

    node.clearNodeState();
  }
}
