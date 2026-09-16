# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
Native storage now supports consuming freeze, shared immutable slices, and
borrowed views. Validated schema trees and flat nullable UInt32 tables support
independent column chunk boundaries. A parameterized Parquet loader decodes flat
numeric columns directly into NuMojo arrays. A bounded writer saves one numeric
column per file, enabling numeric save/load round trips.

An independent native `compact_protocol` module now handles Thrift Compact
metadata encoding. Pyroquet now interprets schema trees and column chunks,
including UInt32 annotations, and validates local chunk/index byte ranges.
Bounded page-header reading and PLAIN numeric body decoding are available with
uncompressed or native Snappy pages. Non-numeric types, other codecs, and
dictionary decoding remain open.

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
pixi run test-codecs-release
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
build/oracle-uv/bin/python tests/check_numeric_write.py
build/oracle-uv/bin/python tests/check_codecs.py
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
uncompressed or Snappy PLAIN values, and RLE/bit-packed hybrid definition levels. Names are
literal, so `a.b` selects a top-level field named `a.b`. Other codecs, dictionary,
nested, encrypted, and non-numeric columns are explicitly unsupported.

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
intermediate full-column value array. Defaults cap values plus validity at 1 GiB;
`max_output_bytes`, `page_limits` and `metadata_limits` are configurable.

CRC fields are not yet verified. Strict payload lengths reject the extra eight
padding bytes emitted by fastparquet's V1 writer; those fixtures are documented
rejection cases. The loader never returns partially decoded output.


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
