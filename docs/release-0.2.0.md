# Pyroquet 0.2.0

A toolchain release: Pyroquet now targets Linux x86-64 with Mojo 1.2.0 and MAX
core 26.7.0. Precompiled Mojo packages are tied to the compiler that built them,
so consumers of 0.1.x on Mojo 1.0 must move to Mojo 1.2 to use this release.

## Changes

- Builds with Mojo 1.2.0 and MAX core 26.7.0.
- NuMojo 0.12.0 (`hb0f4dca_0`) and mojo-snappy 0.2.1 (`hb0f4dca_0`) are pinned
  packaged dependencies from `https://repo.prefix.dev/modular-community`; source
  builds no longer need sibling NuMojo or mojo-snappy checkouts.
- CI builds the current checkout as a Conda package. Annotated version tags
  produce a draft release with package checksums and the source revision.
- Internal dispatch on Parquet and Thrift codes uses Mojo 1.2 `match`
  statements and named spec constants. Accepted and rejected inputs are
  unchanged.

The Pyroquet API, the supported Parquet subset and all limitations are the same
as in [0.1.0](release-0.1.0.md). The release workflow requires both ordinary and
large-file qualification on the tagged commit, plus isolated Conda installation
tests.

Licensed under Apache-2.0; see [third-party notices](../THIRD_PARTY_NOTICES.md).
