package org.apache.hadoop.hdfs;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.fs.permission.FsPermission;
import org.apache.hadoop.util.Progressable;

/**
 * TEST-ONLY INFRASTRUCTURE (not part of HBase, not on the failure path).
 *
 * A DistributedFileSystem that can be told to behave like a flaky HDFS for a bounded
 * window: while an "incident" marker file exists on the local disk, any file created
 * under a region's <code>.tmp</code> directory ends up short on disk -- the tail of the
 * data that the writer handed to the filesystem is not there once the stream is closed,
 * even though every write() and close() returned successfully.
 *
 * This is the fault the ticket describes ("improperly moving partially-written files
 * from TMP ... when a FS error occurs"). It is injected at the *filesystem* layer, so no
 * HBase code is modified and no log/print statement is added anywhere: HBase discovers
 * the state of the file exactly as it would with a real flaky HDFS.
 *
 * Installed via <code>fs.hdfs.impl</code>. It is a real DistributedFileSystem subclass,
 * so every instanceof check, lease recovery path and URI stays untouched.
 *
 * Properties:
 *   hdfs.incident.marker  local path whose existence opens the incident window
 *   hdfs.incident.scope   substring a path must also contain to be affected (default
 *                         none) — used to keep the incident inside one table's data
 *   hdfs.incident.max     how many files may be cut short in total (default 2), so a
 *                         retry loop cannot turn one incident into an unbounded storm
 *   hdfs.incident.keep    fraction of the written bytes that survive (default 0.55)
 *   hdfs.incident.record  local path to append the affected HDFS paths to (harness
 *                         bookkeeping only; nothing is written to any log)
 */
public class DistributedFileSystemImpl extends DistributedFileSystem {

  private static final String MARKER =
      System.getProperty("hdfs.incident.marker", "/tmp/hbase-incident.arm");
  private static final String RECORD =
      System.getProperty("hdfs.incident.record", "/tmp/hbase-incident.record");
  private static final String SCOPE =
      System.getProperty("hdfs.incident.scope", "");
  private static final int MAX =
      Integer.parseInt(System.getProperty("hdfs.incident.max", "2"));
  private static final java.util.concurrent.atomic.AtomicInteger AFFECTED =
      new java.util.concurrent.atomic.AtomicInteger();
  private static final double KEEP =
      Double.parseDouble(System.getProperty("hdfs.incident.keep", "0.55"));

  /** set while this filesystem is rewriting a file itself, so it never wraps its own writes */
  private final ThreadLocal<Boolean> rewriting = new ThreadLocal<Boolean>();

  private boolean affected(Path f) {
    if (f == null || Boolean.TRUE.equals(rewriting.get())) return false;
    String p = f.toString();
    if (p.indexOf("/.tmp/") < 0) return false;
    if (SCOPE.length() > 0 && p.indexOf(SCOPE) < 0) return false;
    if (!new File(MARKER).exists()) return false;
    // bound the blast radius: an incident that keeps cutting every retry short would turn
    // a single failure into an unbounded open/flush retry loop
    return AFFECTED.incrementAndGet() <= MAX;
  }

  @Override
  public FSDataOutputStream create(Path f, FsPermission permission, boolean overwrite,
      int bufferSize, short replication, long blockSize, Progressable progress)
      throws IOException {
    FSDataOutputStream out = super.create(f, permission, overwrite, bufferSize,
        replication, blockSize, progress);
    if (affected(f)) {
      return new FSDataOutputStream(new ShortWriteStream(out, f), null);
    }
    return out;
  }

  /** Passes every byte through, then loses the tail of the file at close(). */
  private final class ShortWriteStream extends OutputStream {
    private final FSDataOutputStream out;
    private final Path path;
    private boolean closed;

    ShortWriteStream(FSDataOutputStream out, Path path) {
      this.out = out;
      this.path = path;
    }

    @Override public void write(int b) throws IOException { out.write(b); }
    @Override public void write(byte[] b) throws IOException { out.write(b); }
    @Override public void write(byte[] b, int off, int len) throws IOException {
      out.write(b, off, len);
    }
    @Override public void flush() throws IOException { out.flush(); }

    @Override public void close() throws IOException {
      if (closed) return;
      closed = true;
      out.close();
      loseTail(path);
    }
  }

  /** Rewrite the file with only the first KEEP fraction of its bytes. */
  private void loseTail(Path p) throws IOException {
    rewriting.set(Boolean.TRUE);
    try {
      long len = super.getFileStatus(p).getLen();
      long keep = (long) (len * KEEP);
      if (keep < 1) keep = len / 2;
      byte[] head = new byte[(int) Math.min(keep, 64L * 1024 * 1024)];
      FSDataInputStream in = super.open(p);
      try {
        in.readFully(0, head);
      } finally {
        in.close();
      }
      // the fully-specified overload: DistributedFileSystem implements this one, so the
      // call lands in the superclass instead of dispatching back into create() above
      FSDataOutputStream out = super.create(p, FsPermission.getDefault(), true, 4096,
          super.getDefaultReplication(), super.getDefaultBlockSize(), null);
      try {
        out.write(head);
      } finally {
        out.close();
      }
      record(p + " " + len + " -> " + head.length);
    } finally {
      rewriting.remove();
    }
  }

  private void record(String line) {
    try {
      FileOutputStream fos = new FileOutputStream(RECORD, true);
      try {
        fos.write((line + "\n").getBytes("UTF-8"));
      } finally {
        fos.close();
      }
    } catch (IOException ignored) {
      // bookkeeping only
    }
  }
}
