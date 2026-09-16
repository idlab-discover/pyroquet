"""Copy a supported numeric/Boolean/binary table, preserving bytes and nulls."""
from std.sys import argv
from pyroquet.table_io import load_table
from pyroquet.table_write import save_table


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("Usage: roundtrip_binary.mojo input.parquet output.parquet")
    var table = load_table(args[1])
    save_table(args[2], table)
