# `test/motivating_example/` — upstream ad-hoc fixture (provenance only)

This directory is the upstream analyzer author's ad-hoc test fixture, copied
verbatim from the canonical build (container `zk_1900_clods`,
`/home/ridevsot/StaticAnalysis/test/motivating_example/`). It is preserved
here for provenance and is **not** the reproduction path for this artifact.

The reproducible path is the interactive driver in
[`../../../repro/motivating_example/`](../../../repro/motivating_example/) (see
[`../../../README.md`](../../../README.md)):

```bash
bash ../../../repro/motivating_example/reproduce.sh --build-image --output /tmp/out
```

That reproduction drives the **full** module
(`bytecode/motivating_example_full.bc`) and reaches the root-cause constant
(`Long.MAX_VALUE` written into `b.size` via `Block.setNumBytes`). The fixture
in this directory is the upstream author's **abridged** fast-module smoke test,
kept only for provenance.

Why the fixture itself is not used for reproduction:

- `test.sh` runs `./static-analysis < input.txt` and `diff`s against
  `output_ref.txt`. A plain `< input.txt` over-feeds the analyzer's interactive
  loop: `input.txt` (`1 0 3 0 0 0 0 -520`) supplies eight values, but only the
  first six are recorded selections for the abridged module. The
  seventh/eighth values drive the analyzer past its last prompt and crash it
  (heap corruption / SIGABRT). The interactive driver instead sends only the
  recorded selections and stops at the next prompt, so it exits cleanly.
- `output_ref.txt` (72,357 bytes) was captured by the upstream author with a
  newer (opaque-pointer) LLVM toolchain. The pinned LLVM 14.0.0 analyzer prints
  typed pointers (`i8 addrspace(1)*` vs `ptr addrspace(1)`), so the transcript
  does not byte-match `output_ref.txt`. The harness therefore compares against a
  fresh LLVM-14 reference
  (`repro/motivating_example/reference/transcript-motivating-example-ref.log`).
- `CLODS.conf` here has the upstream author's host `IRFilePath`
  (`/home/ycx/StaticAnalyisLLVM/bytecode/fast_motivating_example.bc`), which is
  stale in this repo. The harness writes its own `CLODS.conf` pointing at the
  pinned `bytecode/motivating_example_full.bc`.

The abridged module in this fixture follows a different tail path than the full
module (it does not reach the `setNumBytes` / `Long.MAX_VALUE` root cause), so
it is not output-equivalent to the full-module reproduction; it is retained for
upstream provenance only. The reproduction's recorded selections are in
[`../../../repro/motivating_example/reference/manifest.json`](../../../repro/motivating_example/reference/manifest.json).