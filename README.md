# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
Native storage and nullable UInt32 tables are available. The independent
`compact_protocol` package implements bounded Thrift Compact encoding/decoding
using only the Mojo standard library. Parquet I/O is not implemented yet.

## Development

```sh
pixi install --locked
pixi run check
pixi run test-storage-release
pixi run test-table-release
pixi run test-compact-release
pixi run build
pixi run package
pixi run format
```

The supported environment is Linux x86-64. Test utilities live in `tests/`;
brief human-facing save/load examples belong in `examples/`.

Build the standalone codec with `pixi run package-compact`.
