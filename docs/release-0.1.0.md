# Pyroquet 0.1.0

The first source release of Pyroquet brings Parquet reading, in-place numeric
editing with NuMojo, and writing to Linux x86-64 with Mojo 1.0.0.

## Included

- Numeric and Boolean columns, UTF-8 strings, ENUM and binary values.
- Flat tables and supported STRUCT/LIST nesting, preserving null distinctions.
- Uncompressed, native Snappy, GZIP and ZSTD storage.
- V1/V2 page reading, supported dictionary and integer delta decoding, and
  bounded PLAIN-page writing.
- Bit-preserving floating-point I/O, including FLOAT16, signed zero and NaN payloads.
- New-file-only writes, explicit output budgets and malformed-input checks.
- Pinned source setup, precompiled-package builds and independent reader checks.

Start with the [README](../README.md). This is a source release; build it with the
pinned environment described in [building and distribution](distribution.md).
No Python runtime is required by the library. GZIP and ZSTD use external C codec
libraries; parsing, encoding, storage and scheduling run in Mojo.

## Scope and limitations

The supported Parquet subset excludes temporal/decimal types, INT96, MAP,
LIST of LIST, LIST of STRUCT, dictionary writing, DELTA_BYTE_ARRAY,
DELTA_LENGTH_BYTE_ARRAY and BYTE_STREAM_SPLIT. Parquet page CRCs are not verified.
Writers refuse existing destinations and do not guarantee crash durability.
The default 1 GiB output budget is not a process memory limit.

Release qualification requires both the ordinary gate and the large-file gate
on the same clean commit. These cover native tests, ownership compile-fail
checks, packages, malformed inputs, a pinned golden corpus, complete
three-reader comparisons and repeated loads of two files larger than 1 GiB.

Qualification permits explicitly recorded nonpasses, not silent skips.
Fastparquet limitations include FLOAT16/ENUM exposure, trailing NUL bytes,
NaN/null distinctions, nested-parent validity and some V2 dictionary/LIST files.
DuckDB erases some logical widths and schema nullability. Twelve hash-specific
invalid golden fixtures are excluded; strict RLE and metadata-offset
disagreements remain recorded. There is no claim of full three-reader agreement
for every supported nested fixture. See [compatibility notes](compatibility.md)
and the [format contracts](format-and-api.md).

Licensed under Apache-2.0; see [third-party notices](../THIRD_PARTY_NOTICES.md).
