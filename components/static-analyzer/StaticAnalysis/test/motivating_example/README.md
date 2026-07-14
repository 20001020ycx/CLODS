# `test/motivating_example/` — upstream ad-hoc fixture (provenance only)

This directory is the upstream analyzer author's ad-hoc test fixture, copied
verbatim from the canonical build (container `zk_1900_clods`,
`/home/ridevsot/StaticAnalysis/test/motivating_example/`). It is preserved
here for provenance and is **not** the reproduction path for this artifact.

Why it is not used for reproduction:

- `test.sh` runs `./static-analysis < input.txt` and `diff`s against
  `output_ref.txt`. That fixture is keyed to `fast_motivating_example.bc`
  (CLODS.conf `IRFilePath`), a ~33 MB LLVM module that exists in this
  environment only as an un-hydrated Git-LFS pointer whose LFS store
  (`gitlab.dsrg.utoronto.ca`) is not reachable without credentials. A fresh
  run therefore fails with `Could not parse the IR file provided`.
- `output_ref.txt` (72,357 bytes) is the expected output for that *fast* IR,
  not for the 316 MB `bytecode/614good.bc` used by this artifact.
- The analyzer's interactive loop does not exit cleanly on EOF at its prompts,
  so a plain `< input.txt > out; diff` is unreliable regardless of the IR
  (the committed `output.txt` that made `test.sh` appear to pass was a stale
  copy of `output_ref.txt`).

The reproducible path for this artifact uses the hydrated `bytecode/614good.bc`
with the interactive driver in `../../../repro/614good/` (see
[`../../../README.md`](../../../README.md)). The selections in `input.txt`
(`1 0 3 0 0 0 0 -520`) target the fast IR; the verified selections for
`614good.bc` are recorded in
`../../../repro/614good/reference/manifest.json`
(`1 0 3 0 3 0` — round 4 is branch `0` then id `3`).