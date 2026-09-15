"""Machine-readable footer probe for independent fixture validation."""
from std.sys import argv
from pyroquet.format.footer import inspect_footer


def main() raises:
    var args = argv()
    if len(args) != 2:
        raise Error("Usage: inspect_footer FILE")
    var footer = inspect_footer(args[1])
    print(footer.version, footer.num_rows, footer.num_schema_nodes)
    for rows in footer.row_group_rows:
        print(rows)
