# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
Native storage now supports consuming freeze, shared immutable slices, and
borrowed views. Validated schema trees and flat nullable UInt32 tables support
independent column chunk boundaries. A parameterized Parquet loader decodes flat
numeric columns directly into NuMojo arrays; writing remains unimplemented.

An independent native `compact_protocol` module now handles Thrift Compact
metadata encoding. Pyroquet now interprets schema trees and column chunks,
including UInt32 annotations, and validates local chunk/index byte ranges.
Bounded page-header reading and uncompressed PLAIN numeric body decoding are
available. Non-numeric types, compression, and dictionary decoding remain open.

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
python tests/check_numojo_ownership.py
```

The baseline snapshot reads the sibling `../pyroquet` checkout. Generated
fixture artifacts stay under ignored `build/`; the corpus inventory goes to
ignored `docs/private/`. The fixture checks use Fastparquet, DuckDB, and PyArrow
to verify nullable UInt32 values, types, nulls, and row order across V1/V2 pages;
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
uncompressed PLAIN values, and RLE/bit-packed hybrid definition levels. Names are
literal, so `a.b` selects a top-level field named `a.b`. Compressed, dictionary,
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
