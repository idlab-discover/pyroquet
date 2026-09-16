# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
Native storage supports consuming freeze, shared immutable slices, and borrowed
views. Schema-bearing flat tables own arbitrary combinations of ten numeric
dtypes, Boolean, binary, and fixed-length binary columns, with ordered projection
and multi-column load/save. Typed numeric-column
entry points remain available. Reading supports PLAIN and dictionary V1/V2 pages
with uncompressed or native Snappy bodies; writing emits bounded PLAIN pages.
Compact Protocol remains an independently buildable Mojo package.

## Snappy dependency

Snappy is provided by the separate sibling project [`mojo-snappy`](../mojo-snappy/README.md),
pinned to Mojo 1.0.0. `pixi.toml` declares `mojo-snappy = { path = "../mojo-snappy" }`;
`pixi install --locked` builds and installs its `mojo_snappy` package. Keep that
checkout alongside Pyroquet. The library owns raw codec implementation and codec
tests; Pyroquet owns Parquet page integration and its three-reader parity tests.
This local dependency uses Pixi's `pixi-build` preview feature.

Run standalone codec checks from that project:

```sh
pixi run --manifest-path ../mojo-snappy/pixi.toml check
pixi run --manifest-path ../mojo-snappy/pixi.toml -e oracle test-interop
```

## Development

```sh
pixi install --locked
pixi run check
pixi run test-storage-release
pixi run test-table-release
pixi run test-compact-release
pixi run test-metadata-release
pixi run test-pages-release
pixi run test-numojo-release
pixi run test-publication-release
pixi run test-numeric-write-release
pixi run build
pixi run package
pixi run package-compact
pixi run format
```

The initial supported environment is Linux x86-64. The source package is named
`pyroquet`. Smoke checks live in `tests/`; `examples/` is reserved for short
load/save examples as those functions become available.

## Development-only interoperability checks

```sh
python tests/preserve_baseline.py
python tests/check_storage_ownership.py
uv venv build/oracle-uv
uv pip install --python build/oracle-uv/bin/python -r tests/oracle-requirements.txt
build/oracle-uv/bin/python tests/make_uint32_fixtures.py
build/oracle-uv/bin/python tests/inventory_fastparquet.py
build/oracle-uv/bin/python tests/check_compact_interop.py
build/oracle-uv/bin/python tests/check_footer.py
build/oracle-uv/bin/python tests/check_metadata.py
build/oracle-uv/bin/python tests/check_pages.py
build/oracle-uv/bin/python tests/check_numojo.py
build/oracle-uv/bin/python tests/check_numeric.py
build/oracle-uv/bin/python tests/check_numeric_dictionary.py
build/oracle-uv/bin/python tests/check_numeric_write.py
python tests/check_numojo_ownership.py
```

The baseline snapshot reads the sibling `../pyroquet` checkout. Generated
fixture artifacts stay under ignored `build/`; the corpus inventory goes to
ignored `docs/private/`. The fixture checks use Fastparquet, DuckDB, and PyArrow
to verify numeric values, types, nulls, and row order across V1/V2 reads and writes;
these packages are test dependencies only. The ownership check includes
programs that must fail compilation. The inventory reads the sibling
`../fastparquet` checkout.

Compact Protocol checks use Apache Thrift as a development oracle. The native
module imports only the Mojo standard library and builds independently with
`pixi run package-compact`. It handles the data protocol; RPC and IDL code
generation are outside its scope. Footer checks compare selected metadata with
the fixture corpus and exercise malformed inputs in an optimized native binary.

## Metadata inspection

`pyroquet.format.inspect_metadata(path)` returns a `FileMetadata` snapshot with
schema nodes, parent indices, component paths, definition/repetition levels,
and row groups containing typed column-chunk metadata. `SchemaElement.is_uint32()`
recognizes modern `INTEGER(32, false)` and legacy `UINT_32`; modern annotations
have precedence. Other logical annotations are identified by their Thrift union
member ID, but their parameters are not yet interpreted.

`parse_metadata(bytes)` performs structural and schema/chunk consistency checks.
When parsing footer bytes directly, call `validate_file_ranges(metadata,
footer_offset)` before using local offsets. `inspect_metadata` performs both.
Checks reject inconsistent row/byte totals and out-of-file ranges. External
column files and encryption need future resolvers and are explicitly unsupported.
These checks do not validate page contents or guarantee that values are decodable.
The older `pyroquet.format.footer.inspect_footer` remains a lightweight summary.

## Page-header inspection

`pyroquet.format.inspect_column_pages(path, row_group, column)` returns page
headers with their file offsets, payload offsets, and next-page offsets. It reads
metadata and pages from one open file, checks chunk boundaries and page totals,
and skips payloads. V1/V2 data, dictionary, and legacy index headers are supported.
CRC fields are exposed but not verified; page values are not decoded.

`PageLimits` controls maximum header lookahead (64 KiB), page size (256 MiB), and
pages per chunk (100,000). `parse_page_header(bytes)` parses one header prefix;
its `header_size` identifies where the payload begins. `read_page_header` provides
bounded reading from an open file when the caller already has validated chunk
bounds. The compression codec belongs to column metadata, not the page header.

## Direct NuMojo column loading

The current integration uses the sibling `../NuMojo` source checkout (tested at
`515fb28`, Mojo 1.0.0). Package builds and NuMojo tests include that source path;
it is a local source dependency, not a vendored or lockfile-pinned dependency.

```sh
pixi run mojo run -I src -I ../NuMojo examples/load_numojo.mojo file.parquet column_name
```

`pyroquet.numojo_io.load_numeric[dtype](path, column_name)` loads a named top-level
numeric column across all row groups. It supports required/nullable columns, V1/V2 pages,
uncompressed or Snappy PLAIN and dictionary values, and RLE/bit-packed hybrid
definition levels. Dictionary pages use PLAIN entries; data pages accept
RLE_DICTIONARY and legacy PLAIN_DICTIONARY, including PLAIN fallback within a
chunk. Names are literal, so `a.b` selects a top-level field named `a.b`. Other
codecs, nested, encrypted, and non-numeric columns are explicitly unsupported.

Choose a compile-time `DType`: `int8`, `uint8`, `int16`, `uint16`, `int32`,
`uint32`, `int64`, `uint64`, `float32`, or `float64`. For example:

```mojo
from pyroquet.numojo_io import load_numeric

var column = load_numeric[DType.int16]("input.parquet", "temperature")
```

The requested dtype must match the declared numeric meaning; there is no implicit
conversion or runtime type dispatch. Decimal, date/time, Boolean, INT96, Float16,
and unknown logical annotations are rejected. Narrow integers consume four
physical bytes and undergo range checks; floats preserve IEEE bits, including
signed zero and NaN payloads. Output budgets use destination element size.
`load_uint32` remains a compatibility shorthand for `load_numeric[DType.uint32]`.

The returned movable `NumericColumn[dtype]` owns a NuMojo allocation plus packed
validity. `values()` borrows the numerical array read-only without copying;
`validity()` borrows the LSB-first bitmap (empty means all valid). `value(i)`
returns an optional `Scalar[dtype]`, and `size()` / `null_count()` expose counts.
Null slots contain zero; **NuMojo operations do not automatically apply validity**.
The loader fills the final allocation directly, with bounded page buffers and no
intermediate full-column value array. A private dictionary is released at each
chunk boundary. Its physical and decoded size is bounded by
`page_limits.max_page_bytes`; every ID is checked before lookup. Empty
dictionaries support zero-present-value pages whose ID stream contains only the
width byte. Defaults cap values plus validity at 1 GiB;
`max_output_bytes`, `page_limits` and `metadata_limits` are configurable.

CRC fields are not yet verified. Strict payload lengths reject the extra eight
padding bytes emitted by fastparquet's V1 writer; those fixtures are documented
rejection cases. Dictionary streams likewise reject trailing bytes or more than
seven unused IDs in the final packed group. The dictionary regression harness
records affected Fastparquet 2026.5.0 and DuckDB 1.5.5 producer cases, along with
Fastparquet V2 and width-32 reader limitations. The loader never returns partially
decoded output.


## Numeric saving and round trips

`pyroquet.numojo_write.save_numeric[dtype](path, column, options)` borrows a
`NumericColumn[dtype]` and creates a new single-column Parquet file. It supports
all ten numeric dtypes above, required/nullable columns, empty/all-null inputs,
and multiple pages/row groups. Output uses UNCOMPRESSED or SNAPPY PLAIN V1/V2 with matching
modern/legacy integer annotations and null-count statistics. Numeric values,
validity, row order, and floating bits are preserved; source layout and other
metadata are not copied.

```mojo
from pyroquet.numojo_io import load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions

var column = load_numeric[DType.int16]("input.parquet", "temperature")
save_numeric[DType.int16](
    "output.parquet", column, NumericWriteOptions(page_version=2)
)
```

`NumericWriteOptions` defaults to OPTIONAL output because the column container
retains actual validity, not the original schema's nullability marker. Choose
`nullable=False` explicitly for REQUIRED output; nulls then cause an error.
Manually constructed columns require contiguous one-dimensional NuMojo storage
with unit stride. Saving borrows that storage without a full decoded-column copy.

| Option | Default | Meaning |
|---|---:|---|
| `page_version` | 1 | Data page format: 1 or 2; values remain PLAIN |
| `codec` | 0 | Parquet compression: 0 (uncompressed) or 1 (native Snappy) |
| `page_rows` | 65,536 | Maximum rows per page |
| `row_group_rows` | 1,048,576 | Maximum rows per group |
| `max_page_bytes` | 1 MiB | Conservative page-body allocation bound |
| `max_metadata_bytes` | 64 MiB | Encoded footer limit |
| `max_row_groups` | 100,000 | Retained group-record count limit |

V1 remains the default. V2 stores level lengths and page row/null counts in its
header and omits the V1 four-byte level prefix. With `codec=1`, V1 compresses the
whole body; V2 compresses only values and keeps raw values when compression does
not reduce their size. Both formats use the same numeric array and validity.
Snappy encoding and decoding execute in Mojo without an external codec library.

Page and group rows must be positive. The writer rejects options whose
conservative page bound exceeds `max_page_bytes`, using the smaller of the
configured page rows, group rows, and total rows. That bound includes physical
value width, nullable levels, up to five bytes for the hybrid-run header, and
the four-byte level prefix for nullable V1 pages only.
Small header buffers and retained group records are accounted separately;
footer memory grows with groups and column-name length. These are logical
allocation limits, not an RSS ceiling. The encoded file is streamed page by page.
For Snappy, `max_page_bytes` bounds each raw and stored body separately; compressed
expansion may exceed the limit and fail the write. Codec workspace and simultaneous
page buffers are additional memory. V2 reading also assembles levels and decoded
values into a bounded page body; no additional full-column array is created.

The destination appears only after the complete staged file closes. Existing
files, directories and symlinks are never replaced. Publication uses a private
temporary directory beside the destination and an atomic hard link, so the
filesystem must support hard links. Failure triggers best-effort staging cleanup;
process termination can leave temporary files. There is no overwrite/append mode
or crash-durability guarantee (file/directory fsync is not performed).

```sh
pixi run mojo run -I src -I ../NuMojo examples/roundtrip_numeric.mojo input.parquet output.parquet column_name
```

The example selects `DType.int16`; change that parameter to match the input file.


The V2 interoperability harness records known Fastparquet 2026.5.0 public-reader
limitations for nullable integer masks and all-null pages followed by another
page. It still verifies each bounded page through Fastparquet and checks complete
files with Pyroquet, PyArrow, and DuckDB. Exact affected cases are recorded in
`build/numeric-write-checks/v2/results.json`; failed public comparisons are not
counted as passes.

## Mixed numeric tables

```mojo
from pyroquet.table_io import load_table
from pyroquet.table_write import save_table, TableWriteOptions, ColumnWriteOptions

var selected: List[String] = ["temperature", "a.b"]
var table = load_table("input.parquet", selected^)
ref temperature = table.column(0).numeric[DType.int16]()
print(temperature.size(), temperature.null_count())
save_table("output.parquet", table, TableWriteOptions(row_group_rows=65536))
```

`load_table` selects all top-level fields by default. Explicit names are literal
(including dots), preserve requested order, and must be unique and present.
An explicit empty `List[String]` selects zero columns while retaining the file
row count. All footer structure and local chunk/index ranges are validated even
for unselected fields. Only selected page bodies are decoded, so unsupported
unselected types/codecs/encodings can be projected away. Selected nested or
unsupported fields (including UTF-8/STRING) raise an error. CRCs are not checked.

`Table(schema, columns, num_rows)` takes ownership of `List[Column]`; each
`Column(NumericColumn[dtype])` moves its native allocation into a heterogeneous
container. `column(i).dtype()` discovers the type and `numeric[dtype]()` returns
a checked read-only borrow tied to the table. Schema names, dtypes, field order,
nullability and equal lengths are enforced; required fields reject nulls. Tables
are move-only. The legacy UInt32 table constructor and `column(i).value(row)`
shorthand remain, with checked UInt32 access; legacy chunked inputs are normalized
into contiguous storage. Standalone UInt32 chunk helpers remain available.

`save_table` borrows all numeric storage and preserves schema nullability,
including optional columns with no actual nulls. `TableWriteOptions` controls
shared `row_group_rows`, `max_metadata_bytes`, `max_row_groups`, and the aggregate
`max_column_chunks` (default 1,000,000). An optional fourth argument,
`List[ColumnWriteOptions]`, follows schema order and sets each column's `codec`,
`page_version`, `page_rows`, and `max_page_bytes` independently. Defaults match
numeric saving. Pages are staged serially, and all columns share row-group ranges.
Zero-row tables retain their schema. Zero-column writing is explicitly unsupported.
Publication uses the same create-new atomic staging as `save_numeric`.

The reader's `max_output_bytes` is an aggregate budget for all selected value
allocations and packed validity (default 1 GiB). Footer and page limits are
separate, including dictionary workspace. Saving retains bounded chunk records
and a bounded footer; it never copies full decoded columns. These logical limits
are not a process RSS ceiling.

```sh
pixi run mojo run -I src -I ../NuMojo examples/roundtrip_table.mojo input.parquet output.parquet
pixi run test-table-write
pixi run test-table-write-release
python tests/check_table_ownership.py
build/oracle-uv/bin/python tests/check_mixed.py
build/oracle-uv/bin/python tests/check_numeric_dictionary.py
```


## Boolean and raw binary columns

`load_table` / `save_table` support `SchemaNode.BOOLEAN`, `BINARY`, and
`FIXED_BINARY`, mixed with numeric columns. Reads accept PLAIN and binary
PLAIN_DICTIONARY/RLE_DICTIONARY pages, plus RLE Boolean values, in V1/V2 with
UNCOMPRESSED or SNAPPY. Writes emit PLAIN. STRING/UTF8 and other logical byte
annotations remain unsupported; raw bytes are never interpreted as text.

`column.boolean().value(row)` returns `Optional[Bool]`. For binary columns,
`column.binary().is_valid(row)` distinguishes null from empty;
`column.binary().value(row)` borrows an immutable `Span[UInt8]` and raises on
null access. The compiler prevents this span from outliving its column.
`column.kind()` discovers the schema identity; numeric `dtype()` and
`numeric[dtype]()` reject these non-numeric types.

```mojo
from pyroquet.binary_column import BinaryBuilder

var builder = BinaryBuilder(max_bytes=1024)
var bytes: List[UInt8] = [0, 255, 128]
builder.append(Span(bytes))
builder.append_null()
var binary = builder^.freeze()
```

Build a table column with `Column("payload", binary^)` and a matching
`SchemaNode("payload", SchemaNode.BINARY, 0, nullable=True)`. Boolean storage uses
`BooleanColumn(count, packed_values, packed_validity)` with LSB-first bitmaps;
an empty validity bitmap means all valid. Fixed binary uses
`BinaryBuilder(fixed_width=N)` (or `BinaryColumn(..., fixed_width=N)`) and
`SchemaNode(..., SchemaNode.FIXED_BINARY, ..., fixed_width=N)`; present values
must have exactly that positive width. Null values consume no arena bytes.

Binary storage uses one byte arena plus native signed 64-bit offsets and a
separate validity bitmap. Builder `max_bytes` bounds arena bytes; the table
loader's aggregate `max_output_bytes` additionally counts offsets and bitmaps.
Page/dictionary staging and allocator spare capacity are separate from retained
logical payload limits. A dictionary's byte arena plus offsets is bounded by
`PageLimits.max_page_bytes`. Binary writes reject any page, including a single
oversized value, that exceeds `ColumnWriteOptions.max_page_bytes`; reduce
`page_rows` or increase the explicit budget. Failed writes do not publish a file.

```sh
pixi run test-binary
pixi run test-binary-release
python tests/check_binary_ownership.py
pixi run mojo build -O3 -D ASSERT=all -I src -I ../NuMojo tests/roundtrip_binary.mojo -o build/roundtrip-binary
build/oracle-uv/bin/python tests/check_binary.py
build/oracle-uv/bin/python tests/check_binary_wire.py
```

The corpus records complete byte values, nulls, schema, producer versions and
hashes. Known oracle exceptions remain explicit: Fastparquet V2 nullable pages,
Boolean RLE interpretation, trailing NUL loss in fixed binary dictionaries,
and surplus PLAIN writer padding; DuckDB short-stream hybrid padding and its
lack of a fixed-width BLOB writer type. Unsupported comparisons are not passes.
