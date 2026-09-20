"""Full selected numeric read/write/read with exact values and null validation.

CLI: INPUT MAX_BYTES OUTPUT PAGE_VERSION CODEC [COLUMN ...]
Use only disposable outputs. Instrumentation counts include validation access.
"""
from std.sys import argv
from std.memory import bitcast
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)
from std.testing import assert_equal


def main() raises:
    var args = argv()
    var names = List[String]()
    for i in range(6, len(args)):
        names.append(args[i])
    var source = load_table(args[1], names.copy(), Int(args[2]))
    var options = List[ColumnWriteOptions]()
    for c in range(source.num_columns()):
        options.append(
            ColumnWriteOptions(page_version=Int(args[4]), codec=Int(args[5]))
        )
    save_table(args[3], source, TableWriteOptions(), options^)
    var actual = load_table(args[3], names^, Int(args[2]))
    assert_equal(source.num_rows(), actual.num_rows())
    assert_equal(source.num_columns(), actual.num_columns())
    comptime types = (
        DType.int8,
        DType.uint8,
        DType.int16,
        DType.uint16,
        DType.int32,
        DType.uint32,
        DType.int64,
        DType.uint64,
        DType.float16,
        DType.float32,
        DType.float64,
    )
    for c in range(source.num_columns()):
        assert_equal(source.column(c).name(), actual.column(c).name())
        assert_equal(source.column(c).dtype(), actual.column(c).dtype())
        assert_equal(
            source.column(c).null_count(), actual.column(c).null_count()
        )
        assert_equal(
            source.schema().node(c + 1).nullable(),
            actual.schema().node(c + 1).nullable(),
        )
        comptime for t in range(len(types)):
            comptime dtype = types[t]
            if source.column(c).dtype() == dtype:
                ref left = source.column(c).numeric[dtype]()
                ref right = actual.column(c).numeric[dtype]()
                for row in range(source.num_rows()):
                    var a = left.value(row)
                    var b = right.value(row)
                    assert_equal(Bool(a), Bool(b))
                    if a:
                        comptime if dtype == DType.float16:
                            assert_equal(
                                bitcast[DType.uint16](a.value()),
                                bitcast[DType.uint16](b.value()),
                            )
                        elif dtype == DType.float32:
                            assert_equal(
                                bitcast[DType.uint32](a.value()),
                                bitcast[DType.uint32](b.value()),
                            )
                        elif dtype == DType.float64:
                            assert_equal(
                                bitcast[DType.uint64](a.value()),
                                bitcast[DType.uint64](b.value()),
                            )
                        else:
                            assert_equal(a.value(), b.value())
    print("ROUNDTRIP", source.num_rows(), source.num_columns())
