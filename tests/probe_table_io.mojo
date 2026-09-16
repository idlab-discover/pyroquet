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
    var elapsed = perf_counter_ns() - started
    # Complete validation stays outside the timed region.
    var verified = load_table(args[2])
    if verified.num_columns() != count:
        raise Error("Benchmark column count mismatch")
    for c in range(count):
        ref column = verified.column(c).numeric[DType.int64]()
        for row in range(column.size()):
            if not column.value(row) or column.value(row).value() != Int64(row):
                raise Error("Benchmark value mismatch")
    print(elapsed, checksum)
