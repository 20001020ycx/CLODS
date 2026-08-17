## Root cause

The store file `cf/1553916852809385968` is truly corrupt on disk: its last four bytes are `0x62 79 78 66` (integer `1652127846`, ASCII "byxf") instead of a valid HFile format-version int (`1` or `2`). Both the immediate post‑flush reopen that killed RS `60020` (log line 44218 → `DroppedSnapshotException`) and every later region‑open by RS `60021` (log lines 6569330 onwards) hit the exact same "Invalid HFile version: 1652127846" thrown when the trailer is read.

The file was produced by a memstore flush and left in place because the flush path renames the tmp file into `cf/` *before* validating it, so the corrupt file survives the crashing RS and every subsequent RS keeps stumbling over it.

## Exact branches that make the region "report and carry on"

Reader side (why the read blows up):

1. `FixedFileTrailer.readFromStream` (`FixedFileTrailer.java:283-315`)
   - `line 299-300`: `buf.position(buf.limit() - Bytes.SIZEOF_INT); int version = buf.getInt();` — reads the **last 4 bytes of the file** as the version. Here that value = `1652127846`.
   - `line 302-307`:
     ```java
     try { HFile.checkFormatVersion(version); }
     catch (IllegalArgumentException iae) { throw new IOException(iae); }
     ```
     The `catch` fires and wraps the illegal arg as `IOException`.
2. `HFile.checkFormatVersion` (`HFile.java:471-478`)
   - `line 473`: `if (version < MIN_FORMAT_VERSION || version > MAX_FORMAT_VERSION)` — with `MIN=1, MAX=2` (`HFile.java:132, 135`) and `version=1652127846`, the right‑hand test is true, so `line 474` throws `IllegalArgumentException("Invalid HFile version: 1652127846 (expected to be between 1 and 2)")`.

The IOException then propagates: `HFile.pickReaderVersion` (`HFile.java:330`) → `HFile.createReader` (`HFile.java:346`) → `StoreFile.Reader.<init>` (`StoreFile.java:983`) → `StoreFile.open` (`StoreFile.java:444`) → `StoreFile.createReader` (`StoreFile.java:517`).

Region‑open side (why the RS "carries on"):

3. `FamilyStore.<init>` (`FamilyStore.java:215`) unconditionally calls `openStoreFiles()` during region init.
4. `FamilyStore.openStoreFiles` (`FamilyStore.java:253-289`) iterates every file under the family dir. For each candidate it filters:
   - `line 259`: `if (files[i].isDir()) continue;` — skip subdirs.
   - `line 265`: `if (this.fs.getFileStatus(p).getLen() <= 0) { LOG.warn("Skipping " + p + " because it has no content."); continue; }` — skip zero‑length files. (The bad file has ~5 MB, so this branch is **not** taken.)
5. The critical branch is `line 269-279`:
   ```java
   StoreFile curfile = null;
   try {
     curfile = new StoreFile(fs, p, this.conf, this.cacheConf,
         this.family.getBloomFilterType());
     curfile.createReader();
   } catch (IOException ioe) {
     LOG.warn("Cannot read " + p + "; leaving it out of " +
       "this column family's file list. " +
       "Check the file.", ioe);
     continue;
   }
   ```
   Because `createReader()` above throws exactly this `IOException`, the `catch` fires, logs the WARN verbatim (that is the line quoted in the report), and executes `continue` — the file is **not** added to `results`, no rethrow, no delete, no quarantine. The rest of the family/store is loaded normally, `FamilyStore.<init>` returns, `HRegion.initialize` succeeds, and the region comes online without that file.

Every subsequent region open takes the same catch‑and‑continue path (`FamilyStore.java:274-278`), so the file is reported and silently skipped forever.

## Upstream: why the file was left corrupt in `cf/`

`FamilyStore.writeSnapshotFile` (`FamilyStore.java:467-543`) does the flush → validate sequence in the wrong order:

- `line 490-516`: inside `synchronized(flushLock)`, writes KVs and in the `finally` calls `writer.appendMetadata(logCacheFlushId, false)` then `writer.close()`.
- `line 522`: computes `dstPath = StoreFile.getUniqueFile(fs, homedir)` (i.e. under `cf/`).
- `line 526`: `fs.rename(writer.getPath(), dstPath)` — **the not‑yet‑validated file is moved into the live family dir**.
- `line 531-533`:
  ```java
  StoreFile sf = new StoreFile(this.fs, dstPath, this.conf, this.cacheConf,
      this.family.getBloomFilterType());
  StoreFile.Reader r = sf.createReader();      // <-- this is the throw site in log line 44225
  ```
  This is the very call that produced the `DroppedSnapshotException` on RS `60020`.

Because there is no `try/catch` around the rename or the post‑rename reopen (the source even carries the TODO comment at `line 487-489`: "*We can fail in the below block before we complete adding this flush to list of store files. Add cleanup of anything put on filesystem if we fail.*"), the bad file is already in `cf/` when the exception is thrown. `HRegion.internalFlushcache` catches it at `HRegion.java:1197-1212` and turns it into `DroppedSnapshotException`; `MemStoreFlusher.flushRegion` (`MemStoreFlusher.java:399-406`) then aborts RS `60020`. The Master reassigns the region to RS `60021`, whose region‑open runs `openStoreFiles` and hits the `FamilyStore.java:274-278` catch — that is the "reports the file and carries on without it" behavior seen every time the region is opened.
