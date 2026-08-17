## Root cause

The store file `hdfs://…/usertable/…/cf/1553916852809385968` is corrupt: the last 4 bytes of its trailer decode to `1652127846` (and elsewhere in `logs/symptom.log:4693527`, another file yields `1886087525`) — neither is in the valid HFile-version range `[1, 2]`. HBase treats this as an unreadable file and — by design — drops it from the column family's file list and continues opening the region.

## The exact code path

1. `FamilyStore.openStoreFiles()` — `source/org/apache/hadoop/hbase/regionserver/FamilyStore.java:253` — iterates every file under the store's home dir.
   - `files[i].isDir()` → false (`:259`), so not skipped.
   - `this.fs.getFileStatus(p).getLen() <= 0` → false at `:265` (the corrupt file is non‑empty), so the "no content" skip does **not** fire.
   - `curfile.createReader()` at `:273` is invoked inside a `try { … } catch (IOException ioe) { … continue; }`.

2. `StoreFile.createReader()` → `HFile.createReader()` → `HFile.pickReaderVersion()` at `source/org/apache/hadoop/hbase/io/hfile/HFile.java:327-342`, which calls `FixedFileTrailer.readFromStream(fsdis, size)` at line `330`.

3. `FixedFileTrailer.readFromStream()` — `source/org/apache/hadoop/hbase/io/hfile/FixedFileTrailer.java:283-315`:
   - Seeks to `fileSize - MAX_TRAILER_SIZE` (line `286`), reads that tail, and takes the **last int** as the version:
     ```
     buf.position(buf.limit() - Bytes.SIZEOF_INT);   // :299
     int version = buf.getInt();                     // :300
     ```
   - Calls `HFile.checkFormatVersion(version)` at line `303`.

4. `HFile.checkFormatVersion()` — `source/org/apache/hadoop/hbase/io/hfile/HFile.java:471-476`:
   ```java
   if (version < MIN_FORMAT_VERSION || version > MAX_FORMAT_VERSION) {
       throw new IllegalArgumentException("Invalid HFile version: " + version
           + " (expected to be between " + MIN_FORMAT_VERSION + " and " + MAX_FORMAT_VERSION + ")");
   }
   ```
   With `MIN_FORMAT_VERSION = 1` (`HFile.java:132`) and `MAX_FORMAT_VERSION = 2` (`HFile.java:135`), the guard `1652127846 > 2` is true, so it throws.

5. Back in `FixedFileTrailer.readFromStream`, the `IllegalArgumentException` is caught and rethrown as `IOException`:
   ```java
   } catch (IllegalArgumentException iae) {
       throw new IOException(iae);                   // :304-306
   }
   ```

6. That `IOException` bubbles out of `StoreFile.open`/`createReader` into `FamilyStore.openStoreFiles()`'s catch at `FamilyStore.java:274-278`:
   ```java
   } catch (IOException ioe) {
       LOG.warn("Cannot read " + p + "; leaving it out of "
             + "this column family's file list. Check the file.", ioe);
       continue;                                     // :278
   }
   ```
   The `continue` is why the region server keeps opening the region with the remaining files instead of failing.

## Why the version int is garbage

`readFromStream` unconditionally interprets the last 4 bytes of the file as the format version — it does not validate a magic string or a trailer sentinel first (`FixedFileTrailer.java:298-300`). So any file whose trailing 4 bytes are not literally `0x00000001` or `0x00000002` will trigger `checkFormatVersion` to throw. The observed values (`1652127846`, `1886087525`) are large positive 32‑bit integers — consistent with the last four bytes being arbitrary data bytes (e.g., a truncated or partially‑written HFile whose real fixed trailer never got flushed to disk, or a file overwritten by something that isn't an HFile). The important control‑flow point is that the code has no path to distinguish "trailer missing/truncated" from "unsupported version" — both funnel through the same range check at `HFile.java:473`, get wrapped into `IOException` at `FixedFileTrailer.java:306`, and are then silently dropped by `FamilyStore.openStoreFiles()`'s catch/`continue` at `FamilyStore.java:274-278`.
