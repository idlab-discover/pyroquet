"""Development benchmark: mode path iterations columns; no timed value printing."""
from std.sys import argv
from std.time import perf_counter_ns
from pyroquet.numojo_io import load_numeric
from pyroquet.table_io import load_table


def main() raises:
    var args = argv()
    var iterations = Int(args[3])
    var count = Int(args[4])
    var checksum = Int64(0)
    var started = perf_counter_ns()
    for _ in range(iterations):
        if args[1] == "table":
            var table = load_table(args[2])
            for c in range(table.num_columns()):
                ref column = table.column(c).numeric[DType.int64]()
                checksum += column.value(column.size() - 1).value()
        else:
            for c in range(count):
                var column = load_numeric[DType.int64](args[2], "c" + String(c))
                checksum += column.value(column.size() - 1).value()
    print(perf_counter_ns() - started, checksum)
