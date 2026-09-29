# Pyroquet 0.1.1

A maintenance release that moves the native Snappy codec to
[mojo-snappy 0.2.0](https://github.com/idlab-discover/mojo-snappy/releases/tag/v0.2.0).
The target is unchanged: Linux x86-64 with Mojo 1.0.0.

## Changes

- Snappy pages use mojo-snappy 0.2.0, pinned to
  `1bb71bec224d3d262d6a542dd872da7f2a665b9c`. Its encoder is a port of Google
  Snappy 1.2.2 level-1 compression, and its decoder is faster. Snappy pages
  written by Pyroquet can therefore differ byte-for-byte from 0.1.0 output while
  decoding to the same values.
- Page semantics are unchanged: decoding still requires the exact declared page
  size, and encoding still fails past the page output limit.
- The vendored mojo-snappy third-party notice follows the 0.2.0 text.
- Redundant development tasks were removed; the gzip read/write tests now run in
  `pixi run check`.

The Pyroquet API, the supported Parquet subset and all limitations are the same
as in [0.1.0](release-0.1.0.md). Release qualification ran both the ordinary and
large-file gates on the release commit.

Licensed under Apache-2.0; see [third-party notices](../THIRD_PARTY_NOTICES.md).
