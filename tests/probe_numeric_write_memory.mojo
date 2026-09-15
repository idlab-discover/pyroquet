"""Native writer allocation probe: ROWS OUTPUT_PATH [input-only]."""

from std.sys import argv
from numojo.routines.creation import empty
from pyroquet.numojo_io import NumericColumn
from pyroquet.numojo_write import NumericWriteOptions, save_numeric


def main() raises:
    var args = argv()
    if len(args) < 3 or len(args) > 4:
        raise Error(
            "usage: probe_numeric_write_memory ROWS OUTPUT_PATH [input-only]"
        )
    var rows = Int(args[1])
    if rows < 1:
        raise Error("ROWS must be positive")
    var values = empty[DType.int64]([rows])
    for i in range(rows):
        values.unsafe_ptr()[unsafe_offset=i] = Int64(i)
    var column = NumericColumn[DType.int64](values^, List[UInt8](), "value", 0)
    if len(args) == 3:
        save_numeric[DType.int64](
            args[2],
            column,
            NumericWriteOptions(
                page_rows=4096,
                row_group_rows=65536,
                max_page_bytes=65536,
            ),
        )
    elif args[3] != "input-only":
        raise Error("optional mode must be input-only")
    print("rows=", rows, " last=", column.value(rows - 1).value())
