package com.acme.cluster.usage;

/** Opaque identifier for a storage volume attached to a node. */
public final class VolumeId {
  private final String id;

  public VolumeId(String id) { this.id = id; }

  public String getId() { return id; }

  @Override public boolean equals(Object o) {
    return (o instanceof VolumeId) && ((VolumeId) o).id.equals(id);
  }
  @Override public int hashCode() { return id.hashCode(); }
  @Override public String toString() { return id; }
}
