"""Save a loaded numeric column to a new uncompressed Parquet file.

Run: pixi run mojo run -I src -I ../NuMojo examples/roundtrip_numeric.mojo INPUT OUTPUT COLUMN
"""
from std.sys import argv
from pyroquet.numojo_io import load_numeric
from pyroquet.numojo_write import save_numeric


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("Usage: roundtrip_numeric INPUT OUTPUT COLUMN")
    # Choose the compile-time dtype that matches your input column.
    var column = load_numeric[DType.int16](args[1], args[3])
    save_numeric[DType.int16](args[2], column)
    print("Saved", column.size(), "rows and", column.null_count(), "nulls")
