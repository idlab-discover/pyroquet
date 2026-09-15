# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
Native storage, nullable UInt32 tables, and validated Parquet metadata are
available. `pyroquet.format.inspect_column_pages` inspects bounded page headers
and checks chunk/page totals through a shared streaming cursor. Payload decoding
and writing remain unimplemented.

## Development

```sh
pixi install --locked
pixi run check
pixi run test-storage-release
pixi run test-table-release
pixi run test-compact-release
pixi run test-metadata-release
pixi run test-pages-release
pixi run build
pixi run package
pixi run format
```

The supported environment is Linux x86-64. Test utilities live in `tests/`;
brief human-facing save/load examples belong in `examples/`.
