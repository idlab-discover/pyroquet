"""Machine-readable complete mixed-table values; float output is raw bits."""
from std.sys import argv
from std.memory import bitcast
from pyroquet.table_io import load_table


def main() raises:
    var args = argv()
    var projection = Optional[List[String]](None)
    if len(args) > 3:
        var names = List[String]()
        for i in range(4, len(args)):
            names.append(args[i])
        projection = Optional[List[String]](names^)
    var table = load_table(args[1], projection^, Int(args[2]))
    print(table.num_rows(), table.num_columns())
    var schema = table.schema()
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
    for c in range(table.num_columns()):
        print(table.column(c).name())
        print(table.column(c).dtype(), Int(schema.node(c + 1).nullable()))
        comptime for t in range(len(types)):
            comptime dtype = types[t]
            if table.column(c).dtype() == dtype:
                ref column = table.column(c).numeric[dtype]()
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
