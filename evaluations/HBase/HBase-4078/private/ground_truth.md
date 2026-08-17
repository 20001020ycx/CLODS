# Ground truth — HBase-4078 (PRIVATE: never shown to the diagnosis LLM)

Derived from `private/fix.diff` (upstream trunk commit `df9b82c082571b7dfca4380bffaa38f3fd058927`,
"HBASE-4078 Validate store files after flush/compaction", svn `trunk@1183071`, 2011-10-13),
against the pre-fix tree `9814ffbaf0eca469bbded025a1dca81271c6d4e6`.

## Name translation (real ↔ anonymized)

| Real (pre-fix tree) | Anonymized (`source/`, `logs/`) |
|---|---|
| `regionserver/Store.java`, class `Store` | `regionserver/FamilyStore.java`, class `FamilyStore` |
| `Store.internalFlushCache(...)` | `FamilyStore.writeSnapshotFile(...)` |
| `Store.completeCompaction(...)` | `FamilyStore.installCompactionResult(...)` |
| `Store.loadStoreFiles()` | `FamilyStore.openStoreFiles()` |
| `Store.compactStore(...)` | `FamilyStore.mergeStoreFiles(...)` |
| `"Renaming flushed file at X to Y"` | `"Moving new store file X to Y"` |
| `"Failed open of X; presumption is that file was corrupted at flush and lost edits picked up by commit log replay. Verify!"` | `"Cannot read X; leaving it out of this column family's file list. Check the file."` |
| `"Failed move of compacted file X"` | `"Could not place merged file X"` |
| `"Compaction failed <request>"` | `"Merge failed <request>"` |
| `"Failed open of region=R"` | `"Could not bring region online: region=R"` |

Everything else (`StoreFile`, `HRegion`, `HRegionServer`, `MemStoreFlusher`, `CompactionRequest`,
`OpenRegionHandler`, `HFile`, `FixedFileTrailer`, `DroppedSnapshotException`, package paths) keeps
its real name. Full table: `private/anonymization_map.json`.

## What the fix changed

It introduces one new method and calls it at **exactly two production sites**, in both cases
*before* the newly written file leaves the region's `.tmp` directory:

```java
  private void validateStoreFile(Path path) throws IOException {
    StoreFile storeFile = null;
    try {
      storeFile = new StoreFile(this.fs, path, this.conf, this.cacheConf,
          this.family.getBloomFilterType());
      storeFile.createReader();                     // opening it is the validation
    } catch (IOException e) {
      LOG.error("Failed to open store file : " + path + ", keeping it in tmp location", e);
      throw e;                                      // and the file stays in .tmp
    } finally {
      if (storeFile != null) storeFile.closeReader();
    }
  }
```

(The diff also widens `compactStore`/`completeCompaction` from `private` to package-private and
adds `TestCompaction.testCompactionWithCorruptResult`; neither is a behavioural change.)

## Root-cause site A — the flush promotion

**Real:** `src/main/java/org/apache/hadoop/hbase/regionserver/Store.java`, `internalFlushCache`,
**lines 521-533** (the fix inserts `validateStoreFile(writer.getPath());` at line 523, immediately
after `Path dstPath = StoreFile.getUniqueFile(fs, homedir);` and before the rename).
**Anonymized:** `FamilyStore.writeSnapshotFile`, same lines.

```java
    // Write-out finished successfully, move into the right spot
    Path dstPath = StoreFile.getUniqueFile(fs, homedir);
    String msg = "Renaming flushed file at " + writer.getPath() + " to " + dstPath;
    LOG.info(msg);
    status.setStatus("Flushing " + this + ": " + msg);
    if (!fs.rename(writer.getPath(), dstPath)) {          // <-- moved out of .tmp here
      LOG.warn("Unable to rename " + writer.getPath() + " to " + dstPath);
    }
    status.setStatus("Flushing " + this + ": reopening flushed file");
    StoreFile sf = new StoreFile(this.fs, dstPath, ...);
    StoreFile.Reader r = sf.createReader();              // <-- first read, AFTER the move
```

**The wrong condition:** the move into the live column-family directory is **unconditional** —
the only test on the path is `if (!fs.rename(...))`, i.e. *did the rename succeed*, never *can the
file be read*. The readability test (`sf.createReader()`, line 533) is executed **after** the file
is already in the store directory, and when it throws, nothing moves the file back or deletes it.
Required guard: open the file **while it is still in `.tmp`** and promote it only if that succeeds.

## Root-cause site B — the compaction promotion

**Real:** same file, `completeCompaction`, **lines 1221-1232** (the fix inserts
`validateStoreFile(compactedFile.getPath());` at line 1222, immediately inside
`if (compactedFile != null)` and before `StoreFile.rename`).
**Anonymized:** `FamilyStore.installCompactionResult`, same lines.

```java
    if (compactedFile != null) {                         // <-- the only guard there is
      Path p = null;
      try {
        p = StoreFile.rename(this.fs, compactedFile.getPath(),
          StoreFile.getRandomFilename(fs, this.homedir));  // <-- moved out of .tmp here
      } catch (IOException e) {
        LOG.error("Failed move of compacted file " + compactedFile.getPath(), e);
        return null;
      }
      result = new StoreFile(this.fs, p, ...);
      result.createReader();                             // <-- first read, AFTER the move
    }
```

**The wrong condition:** the branch that decides to promote is `compactedFile != null` — *"was
anything written"* — with the `catch` covering only *"did the rename itself fail"*. There is no
condition on the compaction output being openable; `result.createReader()` (line 1232) reads it
only after it is already in the live directory, and the exception it throws leaves it there.

## Why the failure is silent afterwards (consequence site — **not** changed by the fix)

`Store.loadStoreFiles()` lines **269-279** (anonymized `FamilyStore.openStoreFiles`) — the
HBASE-1436 workaround the ticket complains about:

```java
      try {
        curfile = new StoreFile(fs, p, this.conf, this.cacheConf, ...);
        curfile.createReader();
      } catch (IOException ioe) {
        LOG.warn("Failed open of " + p + "; presumption is that file was " +
          "corrupted at flush and lost edits picked up by commit log replay. Verify!", ioe);
        continue;                                        // <-- silently skipped, forever
      }
```

A run that names **only** this site has found where the symptom is *printed*, not what put the
file there. It is not a pass (the fix does not touch it), but it is recorded per run.

## Grading bar (pre-registered, per METHODOLOGY §8 + §10)

**PASS** requires **both** of:

1. **Both root-cause sites**, by code identity (anonymized names accepted, translated via the
   table above): the promotion in the **flush** path (`internalFlushCache` / `writeSnapshotFile`,
   the `fs.rename(writer.getPath(), dstPath)` at line 526) **and** the promotion in the
   **compaction** path (`completeCompaction` / `installCompactionResult`, the
   `StoreFile.rename(...)` inside `if (compactedFile != null)` at lines 1224-1225); and
2. **The exact wrong condition**: the file is moved from the region's `.tmp` directory into the
   live column-family directory **without any check that it can be opened** — the open
   (`createReader()`) happens only *after* the move, so a file that fails to open is already a
   permanent member of the store directory (and is then silently skipped at every later region
   open). Equivalently: the guard should be "opens successfully → promote", but the code's guards
   are only "rename returned true" / "compactedFile != null".

Naming one site only, or naming the sites without the missing-validation condition, or blaming
only the `catch (IOException) { continue; }` in `loadStoreFiles`, or blaming the filesystem
itself, is **FAIL** (no partial credit, §8).

Per-run grade JSONs also record the auditable sub-scores `site_a`, `site_b`,
`condition_stated` and `symptom_site_only`, so alternative bars can be applied without re-running.
