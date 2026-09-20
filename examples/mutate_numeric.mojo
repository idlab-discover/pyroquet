"""Load FLOAT64, apply NuMojo fill, and save to a new ZSTD Parquet file.

Run: pixi run mojo run -I src -I ../NuMojo examples/mutate_numeric.mojo INPUT OUTPUT COLUMN
"""
from std.sys import argv
from pyroquet.numojo_io import load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("Usage: mutate_numeric INPUT OUTPUT COLUMN")
    var column = load_numeric[DType.float64](args[1], args[3])
    var values = column.values_mut()
    values.fill(1.25)
    save_numeric(args[2], column, NumericWriteOptions(codec=6))
    print(
        "Saved",
        column.size(),
        "rows with",
        column.null_count(),
        "unchanged nulls",
    )
