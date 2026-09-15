"""Load a flat UInt32 column from an uncompressed PLAIN Parquet file.

Run: pixi run mojo run -I src -I ../NuMojo examples/load_numojo.mojo FILE COLUMN
"""
from std.sys import argv
from pyroquet.numojo_io import load_numeric


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("Usage: load_numojo FILE COLUMN")
    # Choose the dtype to match the file, e.g. DType.int16 or DType.float64.
    var column = load_numeric[DType.uint32](args[1], args[2])
    print(column.name(), "rows:", column.size(), "nulls:", column.null_count())
    if column.size() > 0:
        var first = column.value(0)
        if first:
            print("First value:", first.value())
        else:
            print("First value: null")
    # column.values() borrows the NuMojo array without copying.
    # Consult column.validity() before numerical operations: null slots contain 0.
