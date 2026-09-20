# Pyroquet

![Pyroquet: a flame mascot beside glowing data columns](assets/branding/pyroquet-logo-169.png)

Read, edit and write Parquet files in Mojo. Pyroquet loads numeric columns into
[NuMojo](https://github.com/Mojo-Numerics-and-Algorithms-group/NuMojo) arrays, so you
can work on their values in place and save the result to a new file.

The library runs in Mojo, with no Python runtime dependency. Snappy is native
Mojo; GZIP and ZSTD use their C codec libraries. Version **0.1.0** targets
**Linux x86-64 and Mojo 1.0.0**.

## Get started

Install Git, Python 3, [Pixi](https://pixi.sh) **0.80.0** and
[uv](https://docs.astral.sh/uv/) **0.12.10**, then:

```sh
git clone https://github.com/idlab-discover/pyroquet.git
cd pyroquet
git checkout v0.1.0
python3 tools/bootstrap.py
pixi run --locked package
```

The bootstrap script installs the pinned toolchain and development readers. It
also creates `NuMojo` and `mojo-snappy` checkouts beside the `pyroquet` directory.
If those directories already exist at different revisions, it stops and leaves
them unchanged. Use a fresh parent directory in that case.

This is a source release. The build produces `build/pyroquet.mojoc`; it does not
install a Python package. See [building and distribution](docs/distribution.md)
for dependency pins and using the precompiled library.

## Load, edit and save a column

Suppose `input.parquet` has a FLOAT64 column named `value`. This program fills its
values with `1.25` and writes a new ZSTD-compressed file:

```mojo
from pyroquet.numojo_io import load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions

def main() raises:
    var column = load_numeric[DType.float64]("input.parquet", "value")
    var values = column.values_mut()
    values.fill(1.25)
    save_numeric("output.parquet", column, NumericWriteOptions(codec=6))
```

Save it as `app.mojo` in the repository root and run:

```sh
pixi run --locked mojo run -I src -I ../NuMojo app.mojo
```

Choose the dtype that matches your input. Null entries stay null, even when you
change the underlying values. The mutable array shares storage with the column;
changes through either handle affect the same values.

**Saving requires a new destination:** Pyroquet refuses to overwrite an existing
file. For complete programs, see the [load and save examples](examples/) and the
[command-line mutation example](examples/mutate_numeric.mojo).

## What can I read and write?

| Feature | Support in 0.1.0 |
|---|---|
| Numbers | Signed and unsigned 8-, 16-, 32- and 64-bit integers; FLOAT16, FLOAT32 and FLOAT64 |
| Other values | Booleans, UTF-8 strings, ENUM, raw bytes and fixed-width binary |
| Nulls | Nullable columns, with nulls distinct from floating-point NaNs |
| Tables | Flat tables; non-repeated STRUCTs and LISTs of primitive values |
| Compression | Uncompressed, Snappy, GZIP and ZSTD |
| Reading | V1/V2 pages; PLAIN, supported dictionary encodings, integer DELTA_BINARY_PACKED and RLE Boolean |
| Writing | PLAIN pages with configurable page and row-group sizes |

Floating-point I/O preserves bits, including signed zero and NaN payloads.
Nested data preserves the difference between null parents, null lists, empty
lists and null elements.

This first release supports a subset of Parquet. Dates and times, decimals,
INT96, MAP, LIST of LIST, LIST of STRUCT, dictionary writing, and several page
encodings are not supported. Parquet page CRCs are not verified. See the
[format and API contracts](docs/format-and-api.md) for the exact boundaries.

Loads have a **1 GiB decoded-output budget** by default. Increase
`max_output_bytes` for larger data. This is not a total memory limit: temporary
buffers, dictionaries and codec workspaces also use memory.

## Validation

Release checks compare complete values, types, null locations, row order and
relevant metadata against **PyArrow, DuckDB and Fastparquet**. They also cover
malformed files, ownership rules, package imports and two files larger than
1 GiB on disk.

```sh
pixi run --locked check-release
pixi run --locked check-release-large
```

Both gates are required for a release. Some reader features cannot be compared
fully; those outcomes remain documented nonpasses. Read the
[compatibility notes](docs/compatibility.md) and
[qualification workflow](tests/release/README.md) for details.

## More information

- [Format and API contracts](docs/format-and-api.md): types, nesting, mutation, memory budgets and file writing.
- [Building and distribution](docs/distribution.md): source dependencies, packages and CI.
- [0.1.0 release notes](docs/release-0.1.0.md): release scope and limitations.

Pyroquet is licensed under [Apache-2.0](LICENSE). See the
[third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses and attribution.

<p align="center">
  <img src="assets/branding/pyroquet-logo-square.png" alt="Pyroquet flame mascot stacking data columns" width="160">
</p>
