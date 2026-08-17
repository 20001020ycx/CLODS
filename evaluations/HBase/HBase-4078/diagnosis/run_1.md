## Root Cause

The store file `hdfs://localhost:8020/hbase/usertable/0c5dd13f705a47db70c9a7e8e0de5c66/cf/1553916852809385968` is **corrupt / not a valid HFile**. Its last 4 bytes — which the reader interprets as the HFile *format version* stored in the trailer — decode to the integer **1 652 127 846** instead of the expected `1` or `2`. The version check rejects it, the exception is caught and only logged as WARN, and the region proceeds to open with that store file missing from the column‑family's file list.

Below is the exact code path, with the branches that determine the outcome.

---

### 1. `FamilyStore.openStoreFiles()` — the *"swallow and continue"* branch

`source/org/apache/hadoop/hbase/regionserver/FamilyStore.java`, lines 253‑289:

```java
253  private List<StoreFile> openStoreFiles() throws IOException {
254    ArrayList<StoreFile> results = new ArrayList<StoreFile>();
255    FileStatus files[] = this.fs.listStatus(this.homedir);
256    for (int i = 0; files != null && i < files.length; i++) {
257      if (files[i].isDir()) { continue; }
258      Path p = files[i].getPath();
259      if (this.fs.getFileStatus(p).getLen() <= 0) {           // (branch A)
260        LOG.warn("Skipping " + p + " because it has no content.");
261        continue;
262      }
263      StoreFile curfile = null;
264      try {
265        curfile = new StoreFile(fs, p, this.conf, this.cacheConf,
266            this.family.getBloomFilterType());
267        curfile.createReader();                                // throws here
268      } catch (IOException ioe) {                              // (branch B ← taken)
269        LOG.warn("Cannot read " + p + "; leaving it out of " +
270          "this column family's file list. Check the file.", ioe);
271        continue;                                              // ★ file dropped
272      }
```

- **Branch A** (`length ≤ 0`) is not taken — the file has content.
- **Branch B** is the exact branch producing the warning in the log. The `continue` on line 271 is what causes the region to open *without* the file (no re-throw, no MOVE‑TO‑CORRUPT, no abort).

This method is invoked from the `FamilyStore` constructor at line 215, which is invoked from `HRegion.instantiateHStore` (line 2409 in `HRegion.java`) as the region is being opened by `RS_OPEN_REGION-…` — exactly the stack you see.

---

### 2. `StoreFile.createReader()` / `open()` → `new Reader(...)` — the trigger

`source/org/apache/hadoop/hbase/regionserver/StoreFile.java`, lines 515‑520 and 443‑445:

```java
515  public Reader createReader() throws IOException {
516    if (this.reader == null) {
517      this.reader = open();                     // → open()
518    }
519    ...
```

```java
443    } else {
444      this.reader = new Reader(this.fs, this.path, this.cacheConf);  // line matches stack
445    }
```

And the `Reader` constructor at lines 981‑985:

```java
981    public Reader(FileSystem fs, Path path, CacheConfig cacheConf)
982        throws IOException {
983      reader = HFile.createReader(fs, path, cacheConf);     // ← stack frame 983
984      bloomFilterType = BloomType.NONE;
985    }
```

No branch here; the code simply delegates to `HFile.createReader`.

---

### 3. `HFile.createReader` → `pickReaderVersion`

`source/org/apache/hadoop/hbase/io/hfile/HFile.java`, lines 344‑347 and 327‑342:

```java
344  public static Reader createReader(FileSystem fs, Path path,
345      CacheConfig cacheConf) throws IOException {
346    return pickReaderVersion(path, fs.open(path),
347        fs.getFileStatus(path).getLen(), true, cacheConf);
```

```java
327  private static Reader pickReaderVersion(Path path, FSDataInputStream fsdis,
328      long size, boolean closeIStream, CacheConfig cacheConf)
329  throws IOException {
330    FixedFileTrailer trailer = FixedFileTrailer.readFromStream(fsdis, size);
331    switch (trailer.getVersion()) {
332    case 1: return new HFileReaderV1(...);
333    case 2: return new HFileReaderV2(...);
338    default:
339      throw new IOException("Cannot instantiate reader for HFile version " +
340          trailer.getVersion());
341    }
342  }
```

The `switch` never runs — the trailer read on line 330 blows up first.

---

### 4. `FixedFileTrailer.readFromStream` — where the version is decoded and validated

`source/org/apache/hadoop/hbase/io/hfile/FixedFileTrailer.java`, lines 283‑307:

```java
283  public static FixedFileTrailer readFromStream(FSDataInputStream istream,
284      long fileSize) throws IOException {
285    int bufferSize = MAX_TRAILER_SIZE;
286    long seekPoint = fileSize - bufferSize;
287    if (seekPoint < 0) { seekPoint = 0; bufferSize = (int) fileSize; }
288
293    istream.seek(seekPoint);
294    ByteBuffer buf = ByteBuffer.allocate(bufferSize);
295    istream.readFully(buf.array(), buf.arrayOffset(),
296        buf.arrayOffset() + buf.limit());
297
298    // Read the version from the last int of the file.
299    buf.position(buf.limit() - Bytes.SIZEOF_INT);
300    int version = buf.getInt();                     // ← 1_652_127_846 here
301
302    try {
303      HFile.checkFormatVersion(version);
304    } catch (IllegalArgumentException iae) {
305      // In this context, an invalid version might indicate a corrupt HFile.
306      throw new IOException(iae);                   // wraps → the IOException seen
307    }
```

- Line 300 pulls the last 4 bytes of the file and interprets them as an `int`. For this file that value is `1652127846`.
- Line 303 calls `HFile.checkFormatVersion(version)`.
- Line 304's `catch` is what wraps the `IllegalArgumentException` into the `java.io.IOException` visible at the top of the stack.

---

### 5. `HFile.checkFormatVersion` — the actual predicate that fails

`source/org/apache/hadoop/hbase/io/hfile/HFile.java`, lines 131‑135 and 471‑478:

```java
131  public static final int MIN_FORMAT_VERSION = 1;
135  public static final int MAX_FORMAT_VERSION = 2;
```

```java
471  public static void checkFormatVersion(int version)
472      throws IllegalArgumentException {
473    if (version < MIN_FORMAT_VERSION || version > MAX_FORMAT_VERSION) {   // ★
474      throw new IllegalArgumentException("Invalid HFile version: " + version
475          + " (expected to be " + "between " + MIN_FORMAT_VERSION + " and "
476          + MAX_FORMAT_VERSION + ")");
477    }
478  }
```

The failing branch is line 473:

```
version (=1_652_127_846) > MAX_FORMAT_VERSION (=2)   →   TRUE
```

so the `throw` on line 474 fires with the exact message you see in the log:
`Invalid HFile version: 1652127846 (expected to be between 1 and 2)`.

---

## Putting the branches together

The failure is dictated by exactly three logical conditions, evaluated in this order:

| # | File : line | Condition (as it evaluates for this file) | Consequence |
|---|-------------|-------------------------------------------|-------------|
| 1 | `HFile.java:473` | `1_652_127_846 < 1  \|\|  1_652_127_846 > 2` → **true** | `IllegalArgumentException("Invalid HFile version: 1652127846 …")` |
| 2 | `FixedFileTrailer.java:302‑306` | The `try` around `checkFormatVersion` catches the `IllegalArgumentException` | Re‑thrown as `java.io.IOException` (the `IOException` at the top of the stack) |
| 3 | `FamilyStore.java:268‑271` | The `catch (IOException ioe)` around `curfile.createReader()` | `LOG.warn("Cannot read … leaving it out of this column family's file list…")` followed by `continue;` — the file is silently omitted, and region opening continues |

## Why it recurs on every open

`openStoreFiles()` is called from the `FamilyStore` constructor (line 215), which itself is called from `HRegion.instantiateHStore` (line 2409) every time the region is opened. Nothing in the failure path renames, quarantines, or deletes the offending file — the `continue` on `FamilyStore.java:271` merely omits it from the in‑memory list for this open. Therefore, the next time the region is opened (e.g., on RS restart or region reassignment), `FileSystem.listStatus` on line 256 lists it again, the trailer's last int is still `1 652 127 846`, `checkFormatVersion` fails again on `HFile.java:473`, and the exact same WARN is logged again. The region continues to run in a degraded state (that store file's data is invisible), and the underlying corrupt/foreign file is never repaired.

## Root cause, in one sentence

The HFile trailer of `…/cf/1553916852809385968` is corrupt — its trailing 4‑byte format‑version field is `1 652 127 846` instead of `1` or `2` — so `HFile.checkFormatVersion` (HFile.java:473) rejects it, `FixedFileTrailer.readFromStream` (FixedFileTrailer.java:306) turns that into an `IOException`, and `FamilyStore.openStoreFiles` (FamilyStore.java:268‑271) catches the `IOException`, logs the `WARN`, and skips the file — repeating on every region open because the file is neither quarantined nor removed.
