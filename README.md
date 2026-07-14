# CLODS — Artifact Review Index

CLODS is a multi-component artifact. Each subdirectory under `components/` is an independently reproducible piece of the artifact. This top-level README is only an index; the review and reproduction guidance for each component lives in that component's own README.

| Component | What it produces |
|---|---|
| [`components/ir-generation`](components/ir-generation/README.md) | LLVM bitcode + readable LLVM IR from Java (the Hadoop HDFS motivating example and a hello-world program) |
| [`components/static-analyzer`](components/static-analyzer/) | Static analysis over the generated LLVM IR |

Components are decoupled and can be reviewed independently. To evaluate one, open its README and follow the reproduction and verification steps documented there.

## License

This repository's scripts and documentation are licensed under the [Apache License, Version 2.0](LICENSE). Vendored or build-time third-party software (e.g., Hadoop, GraalVM) remains under its respective license.