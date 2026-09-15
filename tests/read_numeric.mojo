"""Test probe; runtime dispatch stays outside the typed loader."""
from std.sys import argv, size_of
from std.memory import bitcast
from pyroquet.numojo_io import load_numeric


def read[dtype: DType](path: String, name: String, budget: Int) raises:
    var column = load_numeric[dtype](path, name, budget)
    print(column.size(), column.null_count())
    for i in range(column.size()):
        var value = column.value(i)
        if not value:
            print("null")
        else:
            comptime if dtype == DType.float32:
                print(bitcast[DType.uint32](value.value()))
            elif dtype == DType.float64:
                print(bitcast[DType.uint64](value.value()))
            else:
                print(value.value())


def main() raises:
    var args = argv()
    var budget = 1073741824
    if len(args) > 4:
        budget = Int(args[4])
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
            read[dtype](args[2], args[3], budget)
            return
    raise Error("Unknown test dtype")
