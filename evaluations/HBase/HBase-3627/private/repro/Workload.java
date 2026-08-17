/**
 * Ordinary HBase client traffic for the HBase-3627 reproduction (a small YCSB-style
 * workload).  It only uses the public client API: Put / Get / Scan / Delete against a
 * user table.  It writes NOTHING to the servers' logs and prints only its own summary
 * (op counts, failures) on stdout, which reproduce.sh captures into private/result_*.txt
 * -- never into the symptom log.
 *
 * usage: Workload <table> <threads> <ops-per-thread> <value-size> <mode>
 *   mode = load | mixed | read
 */
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.atomic.AtomicLong;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.client.Delete;
import org.apache.hadoop.hbase.client.Get;
import org.apache.hadoop.hbase.client.HTable;
import org.apache.hadoop.hbase.client.Put;
import org.apache.hadoop.hbase.client.Result;
import org.apache.hadoop.hbase.client.ResultScanner;
import org.apache.hadoop.hbase.client.Scan;
import org.apache.hadoop.hbase.util.Bytes;

public class Workload {
  static final byte[] FAMILY = Bytes.toBytes("f");
  static final byte[] QUAL = Bytes.toBytes("v");

  static final AtomicLong puts = new AtomicLong();
  static final AtomicLong gets = new AtomicLong();
  static final AtomicLong scans = new AtomicLong();
  static final AtomicLong deletes = new AtomicLong();
  static final AtomicLong failures = new AtomicLong();

  public static void main(String[] args) throws Exception {
    final String table = args[0];
    final int threads = Integer.parseInt(args[1]);
    final int ops = Integer.parseInt(args[2]);
    final int valueSize = Integer.parseInt(args[3]);
    final String mode = args.length > 4 ? args[4] : "mixed";
    final int keyspace = args.length > 5 ? Integer.parseInt(args[5]) : 2000000;

    final Configuration conf = HBaseConfiguration.create();
    List<Thread> ts = new ArrayList<Thread>();
    final long t0 = System.currentTimeMillis();
    for (int t = 0; t < threads; t++) {
      final int id = t;
      Thread th = new Thread("workload-" + t) {
        public void run() {
          HTable h = null;
          try {
            h = new HTable(conf, table);
            h.setAutoFlush(false);
            h.setWriteBufferSize(1024 * 1024);
            Random rnd = new Random(id * 7919L + 13);
            byte[] value = new byte[valueSize];
            rnd.nextBytes(value);
            for (int i = 0; i < ops; i++) {
              int k = rnd.nextInt(keyspace);
              byte[] row = Bytes.toBytes(String.format("user%010d", k));
              try {
                if (mode.equals("load")) {
                  Put p = new Put(row);
                  p.add(FAMILY, QUAL, value);
                  h.put(p);
                  puts.incrementAndGet();
                } else if (mode.equals("read")) {
                  h.get(new Get(row));
                  gets.incrementAndGet();
                } else {
                  int r = rnd.nextInt(100);
                  if (r < 55) {
                    Put p = new Put(row);
                    p.add(FAMILY, QUAL, value);
                    h.put(p);
                    puts.incrementAndGet();
                  } else if (r < 85) {
                    h.get(new Get(row));
                    gets.incrementAndGet();
                  } else if (r < 97) {
                    Scan s = new Scan(row);
                    s.addColumn(FAMILY, QUAL);
                    s.setCaching(20);
                    ResultScanner rs = h.getScanner(s);
                    int n = 0;
                    for (Result res : rs) { if (++n >= 20) break; }
                    rs.close();
                    scans.incrementAndGet();
                  } else {
                    h.delete(new Delete(row));
                    deletes.incrementAndGet();
                  }
                }
              } catch (Exception e) {
                failures.incrementAndGet();
              }
              if ((i % 200) == 0) {
                try { h.flushCommits(); } catch (Exception e) { failures.incrementAndGet(); }
              }
            }
            try { h.flushCommits(); } catch (Exception e) { failures.incrementAndGet(); }
          } catch (IOException e) {
            failures.incrementAndGet();
          } finally {
            if (h != null) { try { h.close(); } catch (Exception e) { /* ignore */ } }
          }
        }
      };
      ts.add(th);
      th.start();
    }
    for (Thread th : ts) th.join();
    long ms = System.currentTimeMillis() - t0;
    System.out.println("mode=" + mode + " threads=" + threads + " ops/thread=" + ops
      + " elapsed_ms=" + ms + " puts=" + puts.get() + " gets=" + gets.get()
      + " scans=" + scans.get() + " deletes=" + deletes.get()
      + " failures=" + failures.get());
  }
}
