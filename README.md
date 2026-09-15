# Pyroquet Next

A Mojo-native Parquet rewrite using **Mojo 1.0.0** and Pixi.
The package scaffold compiles; Parquet loading and saving are not implemented yet.

## Development

```sh
pixi install --locked
pixi run check
pixi run build
pixi run package
pixi run format
```

The initial supported environment is Linux x86-64. The source package is named
`pyroquet`. Smoke checks live in `tests/`; `examples/` is reserved for short
load/save examples as those functions become available.
