# Format support and API contracts

This page describes the supported Parquet subset and storage behavior in Pyroquet 0.1.0.

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

Floating I/O preserves bits: signed zero, subnormals, infinities, NaN payloads.
FLOAT16 bypasses FLOAT32; no legacy ConvertedType annotation. Narrow integer
reads check range. STRING/ENUM validate UTF-8; arbitrary bytes require binary.

Flat tables mix all supported types. Nesting: non-repeated STRUCTs containing
STRUCTs, primitives or LISTs of primitives; at most one repeated ancestor per
leaf. Required/optional parents, lists and elements preserve null-parent,
null-list, empty-list and null-element distinctions. Unsupported: MAP, LIST of
LIST, LIST of STRUCT.

Reads: V1/V2 pages, PLAIN, supported PLAIN_DICTIONARY/RLE_DICTIONARY,
integer DELTA_BINARY_PACKED, RLE Boolean. Writes: bounded PLAIN pages;
configurable page/row-group sizes. Unsupported: dictionary writing,
DELTA_BYTE_ARRAY, DELTA_LENGTH_BYTE_ARRAY, BYTE_STREAM_SPLIT, other encodings,
temporal/decimal types, INT96. No Parquet page-CRC verification; GZIP stream
trailers validated independently.

| Storage mode | Codec ID | Runtime requirement |
|---|---:|---|
| Uncompressed | 0 | Mojo runtime |
| Native Snappy | 1 | Pinned mojo-snappy package |
| GZIP | 2 | `libz.so.1`, pinned `libzlib` 1.3.2 |
| ZSTD | 6 | `libzstd.so.1`, pinned `zstd` 1.5.7 |

GZIP/ZSTD load lazily through Mojo FFI, Linux LP64 ABI. V1 compresses full body;
V2 leaves levels raw, compresses values, falls back to raw when compression saves
no bytes.
Readers enforce declared output sizes/page limits; malformed/truncated streams
fail. Retained-output budgets exclude codec workspace and allocator capacity.

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

Match dtype to input schema. See [mutation example](../examples/mutate_numeric.mojo)
and [load/save examples](../examples/).

`values_mut()` returns retained shared NuMojo handle. `fill`, `store` and in-place
element operations affect column and aliases. Reassigning/reshaping handle leaves
column storage, row count and schema unchanged. Handle outlives column, retaining
allocation. `values()` borrows for reading; shared aliases can still mutate
allocation. No allocation-wide immutability guarantee.

Validity stays separate from numeric payloads. `value(row)` returns optional
scalar; `validity()` borrows packed LSB-first bitmap. Empty bitmap = all present.
NuMojo operations ignore validity: changed null-slot payloads remain null, never
written as present. No concurrent mutation while reading/saving.

Shared access also available through `Column.values_mut[dtype]()`,
`Table.values_mut[dtype](column_index)`, `NestedTable.values_mut[dtype](leaf_index)`.
Table schema/nested structure stay fixed. BOOL occupies exactly `ceil(rows / 8)`
bytes; copies share packed storage. No per-row NuMojo Boolean arithmetic promise.

ENUM exposes origin-bound index scalar/span reads; no mutable numeric handles.
`EnumColumn(labels, indices)` snapshots external indices; builders privately
adopt fresh allocations. `set_index(row, code)` checks dictionary bounds; only
existing non-null rows accepted. Column/table wrappers: `set_enum_index`.
Invalid updates preserve values/validity. No vocabulary/null-mask editing.
Round trips may change dictionary order, external codes and unused labels.

## Tables, budgets and publication

Flat I/O: `pyroquet.table_io.load_table` / `pyroquet.table_write.save_table`.
Nested I/O: `pyroquet.nested_io.load_nested_table` /
`pyroquet.nested_write.save_nested_table`. `pyroquet` exports `Schema`, `SchemaNode`,
`Column`, `Table`, `NestedTable`, `StringBuilder`, `EnumBuilder`.
Typed column access checks requested logical identity.

Reader output budget: 1 GiB default; raise `max_output_bytes` for larger loads.
Page/footer/writer budgets bound corresponding staging areas. Output budgets
are not RSS limits: dictionaries, codec workspace, temporary buffers and allocator
capacity add peak memory.

Writers publish **new destinations only**: same-filesystem staging, create-new
hard link. Never overwrite existing paths; failed writes clean staging.
No crash-durability guarantee. Save mutations to new path.

