"""Mixed save driver with intentionally different page boundaries per column."""
from std.sys import argv
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)


def main() raises:
    var args = argv()
    var table = load_table(args[1])
    var columns = List[ColumnWriteOptions]()
    for c in range(table.num_columns()):
        columns.append(
            ColumnWriteOptions(
                page_rows=7 + c * 3,
                page_version=Int(args[3]),
                codec=Int(args[4]) if Int(args[4]) >= 0 else c % 2,
                max_page_bytes=Int(args[6]) if len(args) > 6
                and c == table.num_columns() - 1 else 1048576,
            )
        )
    save_table(
        args[2],
        table,
        TableWriteOptions(
            row_group_rows=61,
            max_metadata_bytes=Int(args[5]) if len(args) > 5 else 67108864,
        ),
        columns^,
    )
