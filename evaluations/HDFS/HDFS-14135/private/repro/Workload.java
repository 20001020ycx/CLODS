import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Random;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FileStatus;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hdfs.HdfsConfiguration;
import org.apache.hadoop.hdfs.MiniDFSCluster;
import org.apache.hadoop.hdfs.web.WebHdfsConstants;
import org.apache.hadoop.hdfs.web.WebHdfsTestUtil;

/**
 * Ordinary WebHDFS traffic against a real (mini) HDFS cluster: writes, reads, listings,
 * renames, checksums and deletes over the WebHDFS REST client.
 *
 * Everything this driver observes is written to a result file; it prints nothing to
 * stdout/stderr, so nothing it says can enter the captured log. It adds no instrumentation
 * to HDFS and reads no internal state.
 */
public class Workload {

  public static void main(String[] args) throws Exception {
    String resultFile = args[0];
    int files = Integer.parseInt(args[1]);

    Configuration conf = new HdfsConfiguration();
    MiniDFSCluster cluster = null;
    FileSystem fs = null;
    int written = 0, read = 0, listed = 0, renamed = 0, deleted = 0, checksums = 0;
    String error = "";
    try {
      cluster = new MiniDFSCluster.Builder(conf).numDataNodes(3).build();
      cluster.waitActive();
      fs = WebHdfsTestUtil.getWebHdfsFileSystem(conf, WebHdfsConstants.WEBHDFS_SCHEME);

      Path dir = new Path("/app/data");
      fs.mkdirs(dir);
      Random rnd = new Random(20260818L);
      byte[] buf = new byte[64 * 1024];

      for (int i = 0; i < files; i++) {
        Path p = new Path(dir, "part-" + i);
        rnd.nextBytes(buf);
        try (OutputStream os = fs.create(p, true)) {
          for (int j = 0; j < 4; j++) {
            os.write(buf);
          }
        }
        written++;

        try (FSDataInputStream in = fs.open(p)) {
          byte[] rb = new byte[buf.length];
          int n, total = 0;
          while ((n = in.read(rb)) > 0) {
            total += n;
          }
          if (total > 0) {
            read++;
          }
        }

        if (fs.getFileChecksum(p) != null) {
          checksums++;
        }

        Path moved = new Path(dir, "part-" + i + ".done");
        if (fs.rename(p, moved)) {
          renamed++;
        }

        FileStatus[] st = fs.listStatus(dir);
        listed += st.length;

        if (i % 3 == 0 && fs.delete(moved, false)) {
          deleted++;
        }
      }
    } catch (Exception e) {
      error = e.toString();
    } finally {
      if (fs != null) {
        try {
          fs.close();
        } catch (IOException ignored) {
          // reported through the result file only
        }
      }
      if (cluster != null) {
        cluster.shutdown();
      }
    }

    try (BufferedWriter w = new BufferedWriter(new FileWriter(resultFile))) {
      w.write("written=" + written + "\n");
      w.write("read=" + read + "\n");
      w.write("checksums=" + checksums + "\n");
      w.write("renamed=" + renamed + "\n");
      w.write("listed=" + listed + "\n");
      w.write("deleted=" + deleted + "\n");
      w.write("error=" + error + "\n");
    }
  }
}
