package clods;

import java.io.PrintStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.NavigableMap;
import java.util.Random;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FileStatus;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hbase.ClusterStatus;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.HColumnDescriptor;
import org.apache.hadoop.hbase.HRegionInfo;
import org.apache.hadoop.hbase.HTableDescriptor;
import org.apache.hadoop.hbase.ServerName;
import org.apache.hadoop.hbase.client.Delete;
import org.apache.hadoop.hbase.client.Get;
import org.apache.hadoop.hbase.client.HBaseAdmin;
import org.apache.hadoop.hbase.client.HTable;
import org.apache.hadoop.hbase.client.Put;
import org.apache.hadoop.hbase.client.Result;
import org.apache.hadoop.hbase.client.ResultScanner;
import org.apache.hadoop.hbase.client.Scan;
import org.apache.hadoop.hbase.util.Bytes;

/**
 * Ordinary HBase client used to drive the reproduction: it creates the table, runs the
 * read/write workload, issues the operator actions (flush / compact / move) and reads
 * back what the cluster reports. Everything it does goes through the normal client API
 * or the normal admin API -- it never touches regionserver internals and never writes
 * to any HBase log. Its own output goes to stdout (the reproduce.sh transcript), which
 * is NOT part of the captured symptom log.
 */
public class Client {

  private static final byte[] FAMILY = Bytes.toBytes("cf");
  private static final int FIELDS = 5;
  private static final int VALUE_SIZE = 180;

  public static void main(String[] args) throws Exception {
    Configuration conf = HBaseConfiguration.create();
    String cmd = args[0];
    PrintStream o = System.out;

    if (cmd.equals("create")) {                       // create <table>
      HBaseAdmin admin = new HBaseAdmin(conf);
      HTableDescriptor desc = new HTableDescriptor(args[1]);
      HColumnDescriptor hcd = new HColumnDescriptor(FAMILY);
      hcd.setMaxVersions(1);
      desc.addFamily(hcd);
      if (!admin.tableExists(args[1])) {
        admin.createTable(desc);
      }
      o.println("created " + args[1]);
      admin.close();

    } else if (cmd.equals("load")) {                  // load <table> <threads> <rows> <startRow>
      load(conf, args[1], Integer.parseInt(args[2]), Integer.parseInt(args[3]),
          Integer.parseInt(args[4]));

    } else if (cmd.equals("mixed")) {                 // mixed <table> <threads> <seconds> <keyspace>
      mixed(conf, args[1], Integer.parseInt(args[2]), Integer.parseInt(args[3]),
          Integer.parseInt(args[4]));

    } else if (cmd.equals("flush")) {                 // flush <table>
      HBaseAdmin admin = new HBaseAdmin(conf);
      admin.flush(args[1]);
      o.println("flush requested for " + args[1]);
      admin.close();

    } else if (cmd.equals("compact")) {               // compact <table>
      HBaseAdmin admin = new HBaseAdmin(conf);
      admin.compact(args[1]);
      o.println("minor compaction requested for " + args[1]);
      admin.close();

    } else if (cmd.equals("majorcompact")) {          // majorcompact <table>
      HBaseAdmin admin = new HBaseAdmin(conf);
      admin.majorCompact(args[1]);
      o.println("major compaction requested for " + args[1]);
      admin.close();

    } else if (cmd.equals("move")) {                  // move <table>
      HBaseAdmin admin = new HBaseAdmin(conf);
      HTable table = new HTable(conf, args[1]);
      NavigableMap<HRegionInfo, ServerName> locs = table.getRegionLocations();
      Map.Entry<HRegionInfo, ServerName> first = locs.firstEntry();
      ClusterStatus cs = admin.getClusterStatus();
      ServerName dest = null;
      for (ServerName sn : cs.getServers()) {
        if (!sn.equals(first.getValue())) { dest = sn; break; }
      }
      o.println("moving region " + first.getKey().getEncodedName()
          + " from " + first.getValue().getServerName()
          + " to " + (dest == null ? "<random>" : dest.getServerName()));
      admin.move(Bytes.toBytes(first.getKey().getEncodedName()),
          dest == null ? null : Bytes.toBytes(dest.getServerName()));
      table.close();
      admin.close();

    } else if (cmd.equals("where")) {                 // where <table>
      HTable table = new HTable(conf, args[1]);
      for (Map.Entry<HRegionInfo, ServerName> e : table.getRegionLocations().entrySet()) {
        o.println(e.getKey().getEncodedName() + " " + e.getValue().getServerName());
      }
      table.close();

    } else if (cmd.equals("storefiles")) {            // storefiles <table>
      // list what is actually sitting in the table's column-family directories
      Configuration c2 = HBaseConfiguration.create();
      FileSystem fs = FileSystem.get(c2);
      Path tableDir = new Path(c2.get("hbase.rootdir"), args[1]);
      FileStatus[] regions = fs.listStatus(tableDir);
      for (int i = 0; regions != null && i < regions.length; i++) {
        if (!regions[i].isDir()) continue;
        Path cfDir = new Path(regions[i].getPath(), "cf");
        if (!fs.exists(cfDir)) continue;
        FileStatus[] files = fs.listStatus(cfDir);
        for (int j = 0; files != null && j < files.length; j++) {
          o.println(files[j].getPath() + " " + files[j].getLen()
              + (files[j].isDir() ? " DIR" : ""));
        }
        Path tmpDir = new Path(regions[i].getPath(), ".tmp");
        if (fs.exists(tmpDir)) {
          FileStatus[] tmp = fs.listStatus(tmpDir);
          for (int j = 0; tmp != null && j < tmp.length; j++) {
            o.println(tmp[j].getPath() + " " + tmp[j].getLen() + " TMP");
          }
        }
      }

    } else if (cmd.equals("count")) {                 // count <table>
      HTable table = new HTable(conf, args[1]);
      Scan scan = new Scan();
      scan.setCaching(500);
      scan.addFamily(FAMILY);
      ResultScanner rs = table.getScanner(scan);
      long n = 0;
      for (Result r = rs.next(); r != null; r = rs.next()) n++;
      rs.close();
      table.close();
      o.println("rows=" + n);

    } else if (cmd.equals("get")) {                   // get <table> <rowIndex>
      HTable table = new HTable(conf, args[1]);
      Result r = table.get(new Get(key(Integer.parseInt(args[2]))));
      o.println("row=" + args[2] + " cells=" + (r == null ? 0 : r.size()));
      table.close();

    } else {
      throw new IllegalArgumentException("unknown command " + cmd);
    }
  }

  private static byte[] key(int i) {
    return Bytes.toBytes(String.format("user%09d", i));
  }

  private static byte[] value(Random rnd) {
    byte[] v = new byte[VALUE_SIZE];
    rnd.nextBytes(v);
    for (int i = 0; i < v.length; i++) {
      v[i] = (byte) ('a' + Math.abs(v[i] % 26));
    }
    return v;
  }

  private static void load(final Configuration conf, final String tableName,
      int threads, final int rows, final int startRow) throws Exception {
    List<Thread> ts = new ArrayList<Thread>();
    final int perThread = rows / threads;
    for (int t = 0; t < threads; t++) {
      final int id = t;
      Thread th = new Thread() {
        public void run() {
          try {
            HTable table = new HTable(conf, tableName);
            table.setAutoFlush(false);
            table.setWriteBufferSize(1024 * 1024);
            Random rnd = new Random(id * 7919L + 13);
            for (int i = 0; i < perThread; i++) {
              int k = startRow + id * perThread + i;
              Put p = new Put(key(k));
              for (int f = 0; f < FIELDS; f++) {
                p.add(FAMILY, Bytes.toBytes("field" + f), value(rnd));
              }
              table.put(p);
            }
            table.flushCommits();
            table.close();
          } catch (Exception e) {
            System.out.println("loader " + id + " failed: " + e);
          }
        }
      };
      ts.add(th);
      th.start();
    }
    for (Thread th : ts) th.join();
    System.out.println("loaded " + rows + " rows from " + startRow);
  }

  private static void mixed(final Configuration conf, final String tableName,
      int threads, final int seconds, final int keyspace) throws Exception {
    List<Thread> ts = new ArrayList<Thread>();
    final long deadline = System.currentTimeMillis() + seconds * 1000L;
    final int[] counters = new int[threads];
    final int[] failures = new int[threads];
    for (int t = 0; t < threads; t++) {
      final int id = t;
      Thread th = new Thread() {
        public void run() {
          Random rnd = new Random(id * 104729L + 7);
          HTable table = null;
          try {
            table = new HTable(conf, tableName);
            table.setAutoFlush(true);
          } catch (Exception e) {
            System.out.println("client " + id + " cannot open table: " + e);
            return;
          }
          while (System.currentTimeMillis() < deadline) {
            int k = rnd.nextInt(keyspace);
            try {
              int op = rnd.nextInt(100);
              if (op < 45) {                       // read
                table.get(new Get(key(k)));
              } else if (op < 80) {                // update
                Put p = new Put(key(k));
                p.add(FAMILY, Bytes.toBytes("field" + rnd.nextInt(FIELDS)), value(rnd));
                table.put(p);
              } else if (op < 95) {                // short scan
                Scan scan = new Scan(key(k));
                scan.setCaching(20);
                scan.addFamily(FAMILY);
                ResultScanner rs = table.getScanner(scan);
                int n = 0;
                for (Result r = rs.next(); r != null && n < 20; r = rs.next()) n++;
                rs.close();
              } else {                             // delete a field
                Delete d = new Delete(key(k));
                d.deleteColumns(FAMILY, Bytes.toBytes("field" + rnd.nextInt(FIELDS)));
                table.delete(d);
              }
              counters[id]++;
            } catch (Exception e) {
              failures[id]++;
            }
            try { Thread.sleep(2); } catch (InterruptedException ie) { break; }
          }
          try { table.close(); } catch (Exception e) { /* ignore */ }
        }
      };
      ts.add(th);
      th.start();
    }
    for (Thread th : ts) th.join();
    int ops = 0, bad = 0;
    for (int i = 0; i < threads; i++) { ops += counters[i]; bad += failures[i]; }
    System.out.println("mixed workload finished: ops=" + ops + " failed=" + bad);
  }
}
