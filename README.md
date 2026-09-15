# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
Native storage supports consuming freeze, shared immutable slices, and
borrowed views. Validated schema trees and flat nullable UInt32 tables support
independent column chunk boundaries. Parquet I/O is not implemented yet.

## Development

```sh
pixi install --locked
pixi run check
pixi run test-storage-release
pixi run test-table-release
pixi run build
pixi run package
pixi run format
```

The supported environment is Linux x86-64. Test utilities live in `tests/`;
brief human-facing save/load examples belong in `examples/`.
