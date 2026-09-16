"""Runtime test driver for typed numeric load/save/load and option failures."""
from std.sys import argv
from std.memory import bitcast
from std.testing import assert_equal
from pyroquet.numojo_io import load_numeric
from pyroquet.numojo_write import NumericWriteOptions, save_numeric


def roundtrip[dtype: DType]() raises:
    var args = argv()
    var column = load_numeric[dtype](String(args[2]), String(args[4]))
    var options = NumericWriteOptions(
        nullable=Bool(Int(args[5])),
        page_rows=Int(args[6]),
        row_group_rows=Int(args[7]),
        max_page_bytes=Int(args[8]),
        max_metadata_bytes=Int(args[9]),
        max_row_groups=Int(args[10]),
        page_version=Int(args[11]),
        codec=Int(args[12]),
    )
    save_numeric[dtype](String(args[3]), column, options)
    var result = load_numeric[dtype](String(args[3]), String(args[4]))
    assert_equal(result.size(), column.size())
    assert_equal(result.null_count(), column.null_count())
    for i in range(column.size()):
        var before = column.value(i)
        var after = result.value(i)
        assert_equal(Bool(before), Bool(after))
        if before:
            comptime if dtype == DType.float32:
                assert_equal(
                    bitcast[DType.uint32](before.value()),
                    bitcast[DType.uint32](after.value()),
                )
            elif dtype == DType.float64:
                assert_equal(
                    bitcast[DType.uint64](before.value()),
                    bitcast[DType.uint64](after.value()),
                )
            else:
                assert_equal(before.value(), after.value())
    print(result.size(), result.null_count())


def main() raises:
    var args = argv()
    if len(args) != 13:
        raise Error(
            "Expected dtype input output column nullable page_rows"
            " row_group_rows max_page_bytes max_metadata_bytes max_row_groups"
            " page_version codec"
        )
    comptime types = (
        DType.int8,
        DType.uint8,
        DType.int16,
        DType.uint16,
        DType.int32,
        DType.uint32,
        DType.int64,
        DType.uint64,
        DType.float32,
        DType.float64,
    )
    comptime for i in range(len(types)):
        comptime dtype = types[i]
        if args[1] == String(dtype):
            roundtrip[dtype]()
            return
    raise Error("Unknown test dtype")
