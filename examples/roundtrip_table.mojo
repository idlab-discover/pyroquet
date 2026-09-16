"""Save selected numeric columns, preserving their schema and native types."""
from std.sys import argv
from pyroquet.table_io import load_table
from pyroquet.table_write import save_table


def main() raises:
    var args = argv()
    var table = load_table(args[1])
    save_table(args[2], table)
    print(table.num_rows(), "rows;", table.num_columns(), "columns")
