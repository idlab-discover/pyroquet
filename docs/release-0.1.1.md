# Pyroquet 0.1.1

A maintenance release that moves the native Snappy codec to
[mojo-snappy 0.2.0](https://github.com/idlab-discover/mojo-snappy/releases/tag/v0.2.0).
The target is Linux x86-64 with Mojo 1.1.0.

## Changes

- NuMojo 0.11.0 and MAX core 26.6.0 are pinned packaged dependencies.
- CI builds the current checkout as a Conda package. Annotated version tags
  produce a draft release with package checksums and the source revision.

- Snappy pages use mojo-snappy 0.2.0, pinned to
  the Mojo 1.1 build `hb0f4dca_1`. Its encoder is a port of Google
  Snappy 1.2.2 level-1 compression, and its decoder is faster. Snappy pages
  written by Pyroquet can therefore differ byte-for-byte from 0.1.0 output while
  decoding to the same values.
- Page semantics are unchanged: decoding still requires the exact declared page
  size, and encoding still fails past the page output limit.
- The vendored mojo-snappy third-party notice follows the 0.2.0 text.
- Redundant development tasks were removed; the gzip read/write tests now run in
  `pixi run check`.

The Pyroquet API, the supported Parquet subset and all limitations are the same
as in [0.1.0](release-0.1.0.md). The release workflow requires both ordinary and large-file qualification on
the tagged commit, plus isolated Conda installation tests.

Licensed under Apache-2.0; see [third-party notices](../THIRD_PARTY_NOTICES.md).
