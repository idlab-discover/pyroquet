from std.sys import argv
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)
from pyroquet.schema import SchemaNode


def main() raises:
    var args = argv()
    var table = load_table(args[1])
    print("rows", table.num_rows())
    for c in range(table.num_columns()):
        ref column = table.column(c)
        print(
            "column",
            column.name(),
            column.kind(),
            table.schema().node(c + 1).fixed_width(),
        )
        for i in range(table.num_rows()):
            if column.kind() == SchemaNode.BOOLEAN:
                var value = column.boolean().value(i)
                if value:
                    print(Int(value.value()))
                else:
                    print("null")
            elif (
                column.kind() == SchemaNode.BINARY
                or column.kind() == SchemaNode.FIXED_BINARY
            ):
                if not column.binary().is_valid(i):
                    print("null")
                else:
                    var bytes = column.binary().value(i)
                    var line = String("bytes")
                    for byte in bytes:
                        line += " " + String(Int(byte))
                    print(line)
            else:
                var value = column.numeric[DType.int32]().value(i)
                if value:
                    print(Int(value.value()))
                else:
                    print("null")
    if len(args) > 2:
        var options = List[ColumnWriteOptions]()
        for c in range(table.num_columns()):
            options.append(
                ColumnWriteOptions(
                    page_rows=7 + c,
                    page_version=Int(args[3]),
                    codec=Int(args[4]),
                    max_page_bytes=1048576,
                )
            )
        save_table(
            args[2], table, TableWriteOptions(row_group_rows=19), options
        )
