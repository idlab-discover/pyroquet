# Pyroquet

A Parquet library written in Mojo, targeting **Linux x86-64 and Mojo 1.0.0**.
Numeric values use NuMojo storage and support in-place NuMojo operations.
Parquet parsing, encoding, storage and scheduling run in Mojo; external C
libraries are used only for GZIP and ZSTD codecs. Python is development tooling.

The 0.1.0 contract is described below. Candidate qualification requires both
release gates; tagging and publishing are separate actions.

## Install from a clean checkout

Install Git, Python 3, Pixi **0.80.0** and uv **0.12.10**, then run:

```sh
python3 tools/bootstrap.py
pixi run package
```

The bootstrap creates missing sibling checkouts, verifies their exact revisions,
installs the locked Pixi environment, and creates the pinned development oracle
environment at `build/oracle-uv`. It refuses to replace mismatched existing
checkouts. The source dependencies are:

| Dependency | Revision |
|---|---|
| NuMojo | `515fb2856f0ecf3d2740a34d958fe168183e1129` |
| mojo-snappy | `ad02f439892d7b7813677d94f8e0951be63d0041` |

Build applications with `pixi run mojo build -I src -I ../NuMojo your_app.mojo`.
`pixi run package` builds `build/pyroquet.mojoc`; `pixi run package-compact` builds
`build/compact_protocol.mojoc`. NuMojo and mojo-snappy remain compile dependencies.
NuMojo also requires the pinned Mojo package dependency `max-core` **26.5.0**.
The runtime needs the Mojo runtime shared libraries from the pinned Pixi
environment. Run through Pixi to select the intended runtime and codec libraries.

## Supported values and storage

| Logical value | Parquet physical representation | In-memory values |
|---|---|---|
| BOOL | BOOLEAN | Packed NuMojo `uint8`, LSB first |
| INT8/UINT8, INT16/UINT16 | INT32 with integer annotation | Matching NuMojo dtype |
| INT32/UINT32, INT64/UINT64 | INT32/INT64 with supported integer annotations | Matching NuMojo dtype |
| FLOAT16 | FIXED_LEN_BYTE_ARRAY of exactly two bytes, FLOAT16 logical annotation | NuMojo `float16` |
| FLOAT32/FLOAT64 | FLOAT/DOUBLE | NuMojo `float32`/`float64` |
| STRING | BYTE_ARRAY with STRING/UTF8 annotation | Native UTF-8 arena and offsets |
| ENUM | BYTE_ARRAY with ENUM annotation | UTF-8 vocabulary and NuMojo `uint32` indices |
| Raw/fixed binary | Unannotated BYTE_ARRAY/FIXED_LEN_BYTE_ARRAY | Native byte arena and offsets |

Floating reads and writes preserve bits, including signed zero, subnormals,
infinities and NaN payloads. FLOAT16 does not convert through FLOAT32 and emits
no legacy ConvertedType annotation. Narrow integer reads validate their range.
STRING and ENUM validate UTF-8; arbitrary bytes belong in binary columns.

Flat tables can mix all these types. Supported nesting is non-repeated STRUCTs
containing STRUCTs, primitive leaves, or LISTs of primitives, with at most one
repeated ancestor per leaf. Required/optional parents, lists and elements retain
null-parent, null-list, empty-list and null-element distinctions. MAP, LIST of
LIST and LIST of STRUCT are outside this release.

Reads accept V1/V2 data pages, PLAIN and supported PLAIN_DICTIONARY /
RLE_DICTIONARY encodings, integer DELTA_BINARY_PACKED, and RLE Boolean values.
Writers emit bounded PLAIN pages with configurable page and row-group sizes.
Dictionary writing, DELTA_BYTE_ARRAY, DELTA_LENGTH_BYTE_ARRAY, BYTE_STREAM_SPLIT,
additional encodings, temporal/decimal types and INT96 are outside the contract.
Parquet page-CRC verification is not implemented. GZIP stream trailers are
validated independently of Parquet page CRCs.

| Storage mode | Codec ID | Runtime requirement |
|---|---:|---|
| Uncompressed | 0 | Mojo runtime |
| Native Snappy | 1 | Pinned mojo-snappy package |
| GZIP | 2 | `libz.so.1`, pinned `libzlib` 1.3.2 |
| ZSTD | 6 | `libzstd.so.1`, pinned `zstd` 1.5.7 |

GZIP and ZSTD load lazily through Mojo FFI using the Linux LP64 ABI. V1 compresses
the full body; V2 keeps levels uncompressed and compresses only values, with raw
fallback when compression does not help. Readers enforce declared output sizes
and configured page limits and reject malformed/truncated streams. Codec workspace
and allocator capacity are separate from retained-output budgets.

## Load, mutate with NuMojo, save

```mojo
from pyroquet.numojo_io import load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions

def main() raises:
    var column = load_numeric[DType.float64]("input.parquet", "value")
    var values = column.values_mut()
    values.fill(1.25)
    save_numeric("output.parquet", column, NumericWriteOptions(codec=6))
```

Choose the dtype matching the input schema. See
[the runnable mutation example](examples/mutate_numeric.mojo) and the other brief
[load/save examples](examples/).

`values_mut()` returns a retained shared NuMojo array handle. `fill`, `store` and
other in-place element operations affect the column and its aliases. Reassigning
or reshaping that returned handle does not change the column's storage, row
count or schema. The handle keeps the allocation alive after the column is gone.
`values()` borrows the handle for reading; it does **not** promise allocation-wide
immutability, since retained shared aliases can mutate the allocation.

Validity is independent of raw numeric values. `value(row)` returns an optional
scalar and `validity()` borrows the packed LSB-first bitmap; an empty bitmap means
all rows are present. NuMojo operations do not apply validity automatically. They
may change null-slot payloads, which remain null and are never written as present
values. Callers must avoid concurrent mutation while reading or saving.

The same shared access is available through `Column.values_mut[dtype]()`,
`Table.values_mut[dtype](column_index)` and
`NestedTable.values_mut[dtype](leaf_index)`. Table schema and nested structural
bookkeeping remain fixed. BOOL value bytes occupy exactly `ceil(rows / 8)` bytes;
copies share that internal packed storage. Per-row NuMojo Boolean arithmetic is
not promised by this representation.

ENUM accessors expose origin-bound index scalar/span reads, not mutable-capable
numeric handles. `EnumColumn(labels, indices)` snapshots externally supplied
indices; builders privately adopt fresh allocations. `set_index(row, code)`
checks dictionary bounds and accepts only existing non-null rows. Column and
table wrappers provide `set_enum_index`. Invalid updates leave values and
validity unchanged. Vocabulary/null-mask editing is outside this release, and
round trips do not preserve dictionary order, external codes or unused labels.

## Tables, budgets and publication

Use `pyroquet.table_io.load_table` / `pyroquet.table_write.save_table` for flat
tables, and `pyroquet.nested_io.load_nested_table` /
`pyroquet.nested_write.save_nested_table` for nested tables. `Schema`, `SchemaNode`,
`Column`, `Table`, `NestedTable`, `StringBuilder` and `EnumBuilder` are exported
from `pyroquet`. Typed column access checks the requested logical identity.

Reader output budgets default to 1 GiB and are configurable through
`max_output_bytes`; increase this explicitly for large materializations. Page,
footer and writer budgets bound their respective staging areas. Logical output
budgets are not process RSS limits: dictionaries, codec workspace, temporary
buffers and allocator capacity contribute to peak memory.

Writers publish **new destinations only**, using same-filesystem staging and a
create-new hard link. Existing paths are never overwritten, and failed writes
clean up staging. Crash durability is not promised. Save to a new path when
applying mutations.

## Qualification and known limitations

```sh
pixi run check-release
pixi run check-release-large
```

Both commands are mandatory for candidate qualification. The ordinary gate runs
native tests, optimized assertion-enabled/disabled acceptance checks, ownership
compile-fail checks, malformed codec cases, package builds, the pinned Fastparquet
golden corpus and complete three-reader comparisons. The large gate reuses the
frozen ordinary exporter, validates two structurally different files exceeding
1 GiB **on disk**, and records repeated complete-load times and peak RSS.
See [the qualification workflow](tests/release/README.md).

Reports distinguish values/bytes, logical types, nulls, row order and metadata.
DuckDB erases some logical distinctions (including FLOAT16 width, fixed binary
width and SQL result nullability). Fastparquet has measured FLOAT16/ENUM exposure,
fixed-byte trailing-NUL, nested-parent validity, NaN/null and V2 dictionary/LIST
limitations. Reviewed failures retain exact fixture hashes and reproducible
controls; they remain nonpasses. Unexpected failures stop qualification.

The golden corpus is pinned to
`f4beb59382e584354c4b2ef2c7a42efa4e97f024`. Its twelve hash-specific invalid-fixture
exclusions remain unchanged. Strict RLE and metadata-offset disagreements remain
visible nonpasses; reader validation is not relaxed to match tolerant oracles.
Security dataset benchmarks and archived performance snapshots are optional local
evidence, not release prerequisites. New query optimizations are outside this
release's scope.

Apache-2.0. See [LICENSE](LICENSE) and
[third-party notices](THIRD_PARTY_NOTICES.md).
