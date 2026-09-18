"""Nested export: explicit schema, parent validity, offsets, bit-exact leaves.

Arguments after filename are literal path components; -- separates selections.
"""
from std.sys import argv
from std.memory import bitcast
from pyroquet.nested_io import load_nested_table
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
    var selection = Optional[List[List[String]]]()
    if len(args) > 2:
        var paths = List[List[String]]()
        var path = List[String]()
        for i in range(2, len(args)):
            if args[i] == "--":
                paths.append(path^)
                path = List[String]()
            else:
                path.append(args[i])
        paths.append(path^)
        selection = paths^
    var table = load_nested_table(args[1], projection=selection^)
    var schema = table.schema()
    print(table.num_rows(), len(schema) - 1)
    comptime types = (DType.int8, DType.uint8, DType.int16, DType.uint16,
        DType.int32, DType.uint32, DType.int64, DType.uint64,
        DType.float32, DType.float64)
    for n in range(1, len(schema)):
        var node = schema.node(n)
        var name = node.name()
        print(hex_bytes(name.as_bytes()))
        if node.kind() == SchemaNode.GROUP or node.kind() == SchemaNode.LIST:
            ref structure = table.structure(n)
            print(node.kind(), node.parent(), Int(node.nullable()), node.fixed_width(), structure.size())
            for row in range(structure.size()):
                if node.kind() == SchemaNode.LIST:
                    print(Int(structure.is_valid(row)), structure.offset(row), structure.offset(row + 1))
                else:
                    print(Int(structure.is_valid(row)))
        else:
            ref leaf = table.leaf(table.leaf_index(n))
            print(node.kind(), node.parent(), Int(node.nullable()), node.fixed_width(), leaf.size())
            if node.kind() == SchemaNode.BOOLEAN:
                ref column = leaf.boolean()
                for i in range(leaf.size()):
                    var value = column.value(i)
                    if value:
                        print(Int(value.value()))
                    else:
                        print("null")
            elif node.kind() == SchemaNode.BINARY or node.kind() == SchemaNode.FIXED_BINARY:
                ref column = leaf.binary()
                for i in range(leaf.size()):
                    if column.is_valid(i):
                        print("x" + hex_bytes(column.value(i)))
                    else:
                        print("null")
            else:
                comptime for t in range(len(types)):
                    comptime dtype = types[t]
                    if leaf.dtype() == dtype:
                        ref column = leaf.numeric[dtype]()
                        for i in range(leaf.size()):
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
