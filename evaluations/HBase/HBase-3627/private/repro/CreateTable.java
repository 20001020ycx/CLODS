/**
 * Creates the workload table pre-split into N regions, using only the public admin API.
 * usage: CreateTable <table> <numRegions>
 */
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.HColumnDescriptor;
import org.apache.hadoop.hbase.HTableDescriptor;
import org.apache.hadoop.hbase.client.HBaseAdmin;
import org.apache.hadoop.hbase.util.Bytes;

public class CreateTable {
  public static void main(String[] args) throws Exception {
    String table = args[0];
    int regions = Integer.parseInt(args[1]);
    int keyspace = args.length > 2 ? Integer.parseInt(args[2]) : 2000000;

    Configuration conf = HBaseConfiguration.create();
    HBaseAdmin admin = new HBaseAdmin(conf);
    if (admin.tableExists(table)) {
      System.out.println("table " + table + " already exists");
      return;
    }
    HTableDescriptor htd = new HTableDescriptor(table);
    HColumnDescriptor hcd = new HColumnDescriptor("f");
    hcd.setMaxVersions(1);
    htd.addFamily(hcd);
    byte[][] splits = new byte[regions - 1][];
    for (int i = 1; i < regions; i++) {
      splits[i - 1] = Bytes.toBytes(String.format("user%010d", (int) ((long) keyspace * i / regions)));
    }
    admin.createTable(htd, splits);
    System.out.println("created " + table + " with " + regions + " regions");
  }
}
