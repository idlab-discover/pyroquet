# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
Native storage supports consuming freeze, shared immutable slices, and borrowed
views. Schema-bearing flat tables own arbitrary combinations of ten numeric
dtypes, Boolean, binary, and fixed-length binary columns, with ordered projection
and multi-column load/save. Typed numeric-column
entry points remain available. Reading supports PLAIN, dictionary and integer DELTA_BINARY_PACKED V1/V2 pages
with uncompressed, native Snappy or GZIP bodies; writing emits bounded PLAIN pages.
Compact Protocol remains an independently buildable Mojo package.

## Snappy dependency

Snappy is provided by the separate sibling project [`mojo-snappy`](../mojo-snappy/README.md),
version **0.1.0**, using Mojo 1.0.0. The integration checkpoint is commit
`ad02f439892d7b7813677d94f8e0951be63d0041`.
`pixi.toml` declares `mojo-snappy = { path = "../mojo-snappy" }`;
`pixi install --locked` builds and installs its `mojo_snappy` package. Keep that
checkout alongside Pyroquet. The library owns raw codec implementation and codec
tests; Pyroquet owns Parquet page integration and its three-reader parity tests.
This local dependency uses Pixi's `pixi-build` preview feature.
The path dependency does not pin the sibling's Git revision. Keep the checkout
at the checkpoint above for reproducible integration checks, and run `pixi install`
after changing it. `python tests/check_snappy_resolution.py` checks source/package
resolution against that commit; it reports installed revision identity as unknown
unless the installed and freshly precompiled package bytes match. Performance
experiments must freeze the effective codec source separately.

Run standalone codec checks from that project:

```sh
pixi run --manifest-path ../mojo-snappy/pixi.toml check
pixi run --manifest-path ../mojo-snappy/pixi.toml -e oracle test-interop
```

## GZIP dependency

Parquet GZIP (`codec=2`) uses RFC 1952 through Mojo standard-library FFI to
zlib. `pixi install --locked` installs the pinned `libzlib` 1.3.2 runtime;
`pixi run` selects its library directory through `LD_LIBRARY_PATH`. The adapter
loads the portable Linux soname `libz.so.1` only when GZIP is used. Outside Pixi,
provide that soname on the loader search path with the Linux x86-64 LP64 ABI.
Missing libraries, missing symbols or incompatible ABI flags raise errors;
UNCOMPRESSED and native SNAPPY do not initialize zlib.

Reading accepts concatenated members (including empty members) and optional
GZIP headers, verifies stream termination and GZIP CRC32/size trailers, and
rejects trailing bytes, truncated members, zlib wrappers and raw DEFLATE.
The declared Parquet page size bounds aggregate output; trailer sizes never
control allocation. V2 levels remain uncompressed and `is_compressed=false`
bypasses decompression. Parquet's separate optional page CRC is not checked.

Codec workspace is separate from page and retained-column budgets: inflate
uses up to a 32 KiB window plus zlib state and a one-byte overflow probe. The
adapter releases zlib state on every recoverable error. Writing uses one member
per compressed page stream, default zlib compression, a 32 KiB window and
memLevel 8 (roughly 256 KiB compression workspace plus state). V1 compressed
staging is capped by the page budget; V2 staging is bounded by `deflateBound`
for the already bounded values section, and is discarded when it does not save
space. Failed compression cannot publish a destination. Zlib allocation failure
raises; Mojo collection allocation exhaustion follows the standard runtime's
process-failure behavior, as existing page and column allocations do.
`tests/check_zlib_abi.py` checks installed headers, C field offsets, initialization,
symbols and the resolved library hash (requires development headers and a C compiler).

After installing the development oracle requirements, run `pixi run test-gzip-reads`,
`pixi run test-gzip-writes`, and
`build/oracle-uv/bin/python tests/check_gzip_failures.py`. The read task generates
independent PyArrow fixtures before running native checks. Three-reader evidence
can be regenerated with `tests/gzip_fixture_oracle.py --verify READER` and
`tests/check_gzip_writes.py --driver WRITER --reader READER`; use the current-source
coverage exporter and `tests/roundtrip_mixed.mojo`, respectively.

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
uncompressed, Snappy or GZIP PLAIN, dictionary and integer DELTA_BINARY_PACKED
values, and RLE/bit-packed hybrid
definition levels. Dictionary pages use PLAIN entries; data pages accept
RLE_DICTIONARY and legacy PLAIN_DICTIONARY, including PLAIN fallback within a
chunk. Names are literal, so `a.b` selects a top-level field named `a.b`. Other
codecs, nested, encrypted, and non-numeric columns are unsupported by this
flat entry point; use `load_nested_table` for the supported nested shapes.

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
and multiple pages/row groups. Output uses UNCOMPRESSED, SNAPPY or GZIP PLAIN V1/V2 with matching
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
| `codec` | 0 | Parquet compression: 0 (uncompressed), 1 (native Snappy), or 2 (GZIP) |
| `page_rows` | 65,536 | Maximum rows per page |
| `row_group_rows` | 1,048,576 | Maximum rows per group |
| `max_page_bytes` | 1 MiB | Conservative page-body allocation bound |
| `max_metadata_bytes` | 64 MiB | Encoded footer limit |
| `max_row_groups` | 100,000 | Retained group-record count limit |

V1 remains the default. V2 stores level lengths and page row/null counts in its
header and omits the V1 four-byte level prefix. With `codec=1` or `codec=2`, V1 compresses the
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
For Snappy and GZIP, `max_page_bytes` bounds each raw and stored body separately; compressed
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
unsupported fields raise an error. CRCs are not checked.

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
UNCOMPRESSED, SNAPPY or GZIP. Writes emit PLAIN. Raw bytes are never inferred to
be text; annotated STRING uses the distinct string API below.

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

## UTF-8 string columns

`SchemaNode.STRING` and `StringColumn` distinguish UTF-8 text from raw binary.
Readers accept BYTE_ARRAY with modern STRING or, when no modern logical type is
present, legacy UTF8. Writers emit both annotations. STRING on another physical
type is rejected. ENUM has its own dictionary specialization described below;
other logical byte annotations remain unsupported.

```mojo
from pyroquet import StringBuilder, Column, SchemaNode

var builder = StringBuilder(max_bytes=1024)
builder.append("hello")
builder.append("λ\0")
builder.append("")
builder.append_null()
var column = Column("text", builder^.freeze())
print(column.string().value(1))
```

Pair this column with `SchemaNode("text", SchemaNode.STRING, 0, nullable=True)`.
`column.string()` is an immutable typed borrow; `value(row)` returns an owned
Mojo stdlib `String` and raises for nulls. Use `is_valid(row)` to distinguish null
from empty text. `column.binary()` rejects strings, preserving logical identity.

String storage shares the binary byte-arena, offsets, and packed-validity design;
it does not allocate a String for every stored row. `StringColumn(binary^)`
validates each value as UTF-8 before exposing it as text and rejects fixed-width
binary storage. Validation never replaces malformed bytes or normalizes Unicode.
Embedded NULs and empty strings are preserved. Dictionary entries are validated
even when no row references them. Budgets follow the binary storage rules above.

Flat and supported nested reads accept PLAIN and PLAIN_DICTIONARY/RLE_DICTIONARY,
including changing row-group dictionaries and PLAIN fallback pages. Writes use
PLAIN. DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY are explicitly unsupported.
No categorical/ENUM semantics are inferred from dictionary encoding.

```sh
pixi run test-strings
build/oracle-uv/bin/python tests/check_string_ownership.py
pixi run mojo build -O3 -D ASSERT=none -I src -I ../NuMojo tests/test_string_io.mojo -o build/test-string-io
build/oracle-uv/bin/python tests/string_fixture_oracle.py --verify build/test-string-io
```

The fixture manifest and full parity results are retained in `build/strings/`.
Reader-specific type or nested-data limitations are recorded explicitly and do
not count as successful comparisons.

## ENUM string dictionaries

`SchemaNode.ENUM` preserves Parquet ENUM independently of STRING and independent
of page encoding. Modern ENUM is authoritative; legacy ConvertedType ENUM is
used only when the modern logical annotation is absent. Both require BYTE_ARRAY.
`load_table` and the supported nested loader materialize ENUM as `EnumColumn`.

```mojo
from pyroquet import EnumBuilder, Column, SchemaNode

var builder = EnumBuilder(row_count=4, max_output_bytes=1024)
builder.append("blue")
builder.append_null()
builder.append("")
builder.append("blue")
var column = Column("color", builder^.freeze())
print(column.enumeration().value(3))
```

Use `SchemaNode("color", SchemaNode.ENUM, 0, nullable=True)` for this column.
`enumeration()` returns an immutable borrow; `labels()` borrows a `StringColumn`
and `indices()` borrows `NumericColumn[DType.uint32]`. Its packed validity
distinguishes null indices from index zero. `is_valid(row)` checks presence;
`value(row)` returns an owned stdlib String and raises on null or out-of-range
access. ENUM rejects ordinary `string()`, `binary()`, and `numeric[...]()` column
borrows. `EnumColumn(labels^, indices^)` also accepts directly constructed storage
and checks that labels are unique and non-null and all present indices are valid.
The column is move-only; its numojo index allocation remains exclusively owned.

The builder requires the final row count and consumes itself on `freeze()`.
It interns exact UTF-8 bytes into one label arena, including empty strings and
embedded NULs, without Unicode normalization. `max_labels` defaults to 2^32,
covering the full UInt32 index range, and may be reduced explicitly. Allocation,
cardinality and index bounds are checked even with compiler assertions disabled.
The output-byte budget includes `4 * rows`, `ceil(rows / 8)` validity bytes,
`8 * (labels + 1)` offset bytes and unique label bytes. Temporary hash keys and
entries are bounded by unique payload/count but, like allocator spare capacity
and page/codec workspaces, are outside that logical output budget.

Reads accept PLAIN and existing dictionary encodings, including duplicate source
dictionary entries, different dictionaries across row groups, and PLAIN fallback
pages. Labels are merged by bytes into a column-wide dictionary as encountered;
source dictionary IDs are never treated as globally stable codes. All source
dictionary labels are UTF-8 validated, including unused ones. Writes resolve
indices to labels and emit PLAIN BYTE_ARRAY with both ENUM annotations.

Internal index order does not define value order: Parquet ENUM ordering is
unsigned byte-wise ordering of the labels. There is no ordered categorical API,
external code identity, complete vocabulary declaration, pandas/Arrow metadata
serialization, or arbitrary category value type. A direct constructor may retain
unused labels, but Parquet round trips do not promise their preservation or the
same dictionary order. Dictionary-encoded STRING remains STRING. Delta byte-array
encodings and dictionary page emission remain outside this implementation.

```sh
pixi run test-enums
build/oracle-uv/bin/python tests/check_enum_ownership.py
build/oracle-uv/bin/python tests/check_enum_nested_ownership.py
pixi run mojo build -O3 -D ASSERT=none -I src -I ../NuMojo tests/test_enum_io.mojo -o build/test-enum-io-none
build/oracle-uv/bin/python tests/enum_fixture_oracle.py --verify build/test-enum-io-none
```

Genuine ENUM fixture annotations, complete values, producer versions and oracle
results are retained under `build/enums/`. Reader exposure as strings is
spec-compliant; unsupported behavior and mismatches are explicit nonpasses.

## Nested STRUCT and primitive LIST tables

`pyroquet.nested_io.load_nested_table` and
`pyroquet.nested_write.save_nested_table` use `NestedTable`, which owns a logical
schema tree, typed `Column` leaves, and `NestedStructure` parent validity and LIST
offsets. Non-repeated STRUCTs may contain STRUCTs, primitive fields, or LISTs of
primitives. Required/optional parents and elements are supported. Each leaf may
have at most one repeated ancestor. Primitive support is the same ten numeric
types, Boolean, unannotated raw binary, fixed binary, STRING, and ENUM as flat tables.
MAP, LIST of LIST, LIST of STRUCT, and other new logical types remain unsupported.
Annotated text is never treated as raw binary.

A STRUCT child retains one slot per parent row; its slot is null when the parent
is absent. LIST offsets address compact element slots, including null elements.
Parent validity distinguishes null STRUCT from present STRUCT with null children,
and null LIST from empty LIST. `table.structure(schema_index)` borrows structure;
`table.leaf(table.leaf_index(schema_index))` borrows typed leaf storage. Borrowed
views cannot outlive their owners. Saving borrows the table and publishes a new
file atomically only after successful completion.

Nested projection uses explicit component arrays, for example
`projection=[["record", "count"], ["record", "samples"]]`. Components are literal:
`["a.b"]` selects a field named `a.b`, while `["a", "b"]` traverses STRUCT `a`.
Selected fields and their ancestors are retained in source schema order. Selecting
an entire group selects every descendant and fails if any selected descendant is
unsupported; selecting supported STRUCT descendants alone may succeed. Duplicate
or overlapping selections raise. LIST is a terminal selection; its element cannot
be projected separately. An explicit empty selection retains the row count.
The existing `load_table` literal top-level names and requested ordering are
unchanged.

Readers interpret supported legacy primitive LIST layouts using the local Parquet
compatibility rules, including repeated primitives and two-level LISTs. Physical
LIST wrapper names normalize to a logical child named `element`; STRUCT and field
names remain literal. Writers emit canonical three-level LISTs. Logical LIST
storage therefore requires its primitive child to be named `element`.

Nested readers reconstruct rows from bounded repetition/definition streams,
validate sibling parent validity, accept legal unindexed V1 row continuations,
and require V2 row-aligned pages. Two passes determine exact child cardinalities
before typed allocation. The aggregate output limit charges retained validity,
LIST/binary offsets and leaf values/bytes. Metadata, page, dictionary and codec
workspaces have separate limits. Nested writers stage bounded PLAIN pages with
row-aligned cuts. If a configured page exceeds the staging limit, writing raises
without publishing the destination; reduce `page_rows` to fit multiple-row pages.
A single oversized row/list requires a larger staging limit. Per-leaf column options follow logical
schema primitive order. V1/V2 and existing UNCOMPRESSED, SNAPPY and GZIP behavior
apply to nested pages as well.

Physical INT32/INT64 `DELTA_BINARY_PACKED` decoding is available in flat and
nested readers. Decoding applies two's-complement wrapping, then existing logical
matching and narrow integer range checks. Legal final miniblock padding is
accepted; malformed counts, parameters, widths, truncation and trailing payload
raise. Writers retain PLAIN defaults; delta writing is not implemented.

Focused development checks include `pixi run test-delta`,
`pixi run test-nested-table`, `pixi run test-nested-levels`,
`pixi run test-nested-read`, `pixi run test-nested-write`, and
`build/oracle-uv/bin/python tests/check_nested_ownership.py`. Independent fixture utilities are
`tests/delta_fixture_oracle.py` and `tests/nested_fixture_oracle.py`; use the pinned
oracle environment. Oracle errors and unsupported representations are recorded
separately, especially Fastparquet representations that lose STRUCT parent
validity. Such comparisons do not count as passes.
