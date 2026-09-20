"""Full-table test export; hex names/bytes and bit-exact floating values."""
from std.sys import argv
from std.memory import bitcast
from pyroquet.table_io import load_table
from pyroquet.schema import SchemaNode


def hex_bytes(data: Span[UInt8, _]) -> String:
    var result = String()
    var digits = String("0123456789abcdef")
    for byte in data:
        result += String(digits[byte=Int(byte >> 4)])
        result += String(digits[byte=Int(byte & 15)])
    return result


def main() raises:
    var args = argv()
    var table = load_table(args[1])
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
        DType.float16,
        DType.float32,
        DType.float64,
    )
    for c in range(table.num_columns()):
        var node = schema.node(c + 1)
        var name = table.column(c).name()
        print(hex_bytes(name.as_bytes()))
        print(node.kind(), Int(node.nullable()), node.fixed_width())
        if node.kind() == SchemaNode.BOOLEAN:
            ref column = table.column(c).boolean()
            for i in range(table.num_rows()):
                var value = column.value(i)
                if value:
                    print(Int(value.value()))
                else:
                    print("null")
        elif (
            node.kind() == SchemaNode.BINARY
            or node.kind() == SchemaNode.FIXED_BINARY
        ):
            ref column = table.column(c).binary()
            for i in range(table.num_rows()):
                if column.is_valid(i):
                    print("x" + hex_bytes(column.value(i)))
                else:
                    print("null")
        else:
            comptime for t in range(len(types)):
                comptime dtype = types[t]
                if table.column(c).dtype() == dtype:
                    ref column = table.column(c).numeric[dtype]()
                    for i in range(column.size()):
                        var value = column.value(i)
                        if not value:
                            print("null")
                        else:
                            comptime if dtype == DType.float16:
                                print(bitcast[DType.uint16](value.value()))
                            elif dtype == DType.float32:
                                print(bitcast[DType.uint32](value.value()))
                            elif dtype == DType.float64:
                                print(bitcast[DType.uint64](value.value()))
                            else:
                                print(value.value())
