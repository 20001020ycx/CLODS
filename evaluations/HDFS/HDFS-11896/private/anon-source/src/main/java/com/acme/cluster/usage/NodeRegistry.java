package com.acme.cluster.usage;

import java.util.HashMap;
import java.util.Map;

/**
 * The cluster controller's registry of nodes. Handles (re-)registration,
 * heartbeats, and expiry of nodes that stop heartbeating.
 */
public class NodeRegistry {
  private static final Log LOG = Log.getLog(NodeRegistry.class);

  private final Map<String, NodeUsageRecord> nodeMap = new HashMap<>();
  private final LivenessTracker livenessTracker;
  private final ShardManager shardManager;

  public NodeRegistry(LivenessTracker livenessTracker, ShardManager shardManager) {
    this.livenessTracker = livenessTracker;
    this.shardManager = shardManager;
  }

  public NodeUsageRecord getNode(String nodeId) {
    return nodeMap.get(nodeId);
  }

  /**
   * Register a node. If the node is already known (e.g. it went away and came
   * back), its existing record is reused and the registration is also treated
   * as a heartbeat.
   */
  public synchronized void registerNode(NodeUsageRecord node) {
    LOG.info("REGISTER: register node from " + node);
    NodeUsageRecord existing = nodeMap.get(node.getNodeId());
    if (existing != null) {
      node = existing;
    } else {
      nodeMap.put(node.getNodeId(), node);
    }
    // also treat the registration message as a heartbeat
    livenessTracker.register(node);
  }

  /** Called when the liveness monitor finds a node has stopped heartbeating. */
  public synchronized void removeExpiredNode(NodeUsageRecord node) {
    LOG.info("EXPIRE: lost heartbeat from " + node);
    removeNode(node);
  }

  private void removeNode(NodeUsageRecord node) {
    livenessTracker.dropNode(node);
    shardManager.releaseNodeShards(node);
  }

  /** Process a real heartbeat from an already-registered node. */
  public synchronized void onHeartbeat(NodeUsageRecord node,
      UsageReport[] reports, long cacheCapacity, long cacheUsed,
      int xceiverCount) {
    livenessTracker.onHeartbeat(node, reports, cacheCapacity, cacheUsed,
        xceiverCount);
  }
}
