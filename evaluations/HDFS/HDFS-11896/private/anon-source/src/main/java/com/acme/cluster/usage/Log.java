package com.acme.cluster.usage;

import java.text.SimpleDateFormat;
import java.util.Date;

/** Minimal logger used by the usage-accounting components. */
public final class Log {
  private final String tag;
  private Log(String tag) { this.tag = tag; }

  public static Log getLog(Class<?> c) { return new Log(c.getSimpleName()); }

  public void info(String msg) {
    String ts = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss,SSS").format(new Date());
    System.out.println(ts + " INFO  " + tag + " - " + msg);
  }
}
