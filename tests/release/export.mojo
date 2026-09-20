"""Bounded binary qualification export; no Python in native execution.

CLI: PATH OUTPUT_DIR MAX_OUTPUT_BYTES [measured repetitions]. '-' times loads.
Each node has .bin records (valid:u8, payload:u64 LE). LIST payload is end offset;
byte leaves use end byte offset into .data. GROUP payload is zero. Scalars use
exact bits (signed integers sign extended). Null scalar payload is zero.
"""
from std.sys import argv
from std.time import perf_counter_ns
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


def record(mut buffer: List[UInt8], valid: Bool, bits: UInt64):
    buffer.append(UInt8(valid))
    comptime for j in range(8):
        buffer.append(UInt8(bits >> UInt64(j * 8)))


def main() raises:
    var args = argv()
    var repetitions = 0
    if len(args) > 4:
        repetitions = Int(args[4])
    for iteration in range(repetitions + 1):
        var start = perf_counter_ns()
        var table = load_nested_table(args[1], max_output_bytes=Int(args[3]))
        print(
            "TIME" if iteration else "WARMUP",
            perf_counter_ns() - start,
            table.num_rows(),
            table.num_leaves(),
        )
        if args[2] == "-" or iteration:
            continue
        var schema = table.schema()
        print("TABLE", table.num_rows(), len(schema) - 1)
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
        for n in range(1, len(schema)):
            var node = schema.node(n)
            var name = node.name()
            var count: Int
            var prefix = args[2] + "/" + String(n)
            var file = open(prefix + ".bin", "w")
            var buffer = List[UInt8](capacity=589824)
            var payload = UInt64(0)
            if (
                node.kind() == SchemaNode.GROUP
                or node.kind() == SchemaNode.LIST
            ):
                ref structure = table.structure(n)
                count = structure.size()
                for row in range(count):
                    var bits = UInt64(0)
                    if node.kind() == SchemaNode.LIST:
                        bits = UInt64(structure.offset(row + 1))
                    record(buffer, structure.is_valid(row), bits)
                    if len(buffer) >= 589824:
                        file.write_bytes(buffer)
                        buffer.clear()
            else:
                ref leaf = table.leaf(table.leaf_index(n))
                count = leaf.size()
                if (
                    node.kind() == SchemaNode.STRING
                    or node.kind() == SchemaNode.ENUM
                    or node.kind() == SchemaNode.BINARY
                    or node.kind() == SchemaNode.FIXED_BINARY
                ):
                    var data = open(prefix + ".data", "w")
                    var bytes = List[UInt8](capacity=65536)
                    for row in range(count):
                        var valid: Bool
                        if (
                            node.kind() == SchemaNode.STRING
                            or node.kind() == SchemaNode.ENUM
                        ):
                            var value = String()
                            if node.kind() == SchemaNode.STRING:
                                valid = leaf.string().is_valid(row)
                                if valid:
                                    value = leaf.string().value(row)
                            else:
                                valid = leaf.enumeration().is_valid(row)
                                if valid:
                                    value = leaf.enumeration().value(row)
                            for byte in value.as_bytes():
                                bytes.append(byte)
                                payload += 1
                                if len(bytes) >= 65536:
                                    data.write_bytes(bytes)
                                    bytes.clear()
                        else:
                            valid = leaf.binary().is_valid(row)
                            if valid:
                                for byte in leaf.binary().value(row):
                                    bytes.append(byte)
                                    payload += 1
                                    if len(bytes) >= 65536:
                                        data.write_bytes(bytes)
                                        bytes.clear()
                        record(buffer, valid, payload)
                        if len(buffer) >= 589824:
                            file.write_bytes(buffer)
                            buffer.clear()
                    data.write_bytes(bytes)
                elif node.kind() == SchemaNode.BOOLEAN:
                    for row in range(count):
                        var value = leaf.boolean().value(row)
                        record(
                            buffer,
                            Bool(value),
                            UInt64(value.value()) if value else UInt64(0),
                        )
                        if len(buffer) >= 589824:
                            file.write_bytes(buffer)
                            buffer.clear()
                else:
                    comptime for t in range(len(types)):
                        comptime dtype = types[t]
                        if node.kind() == SchemaNode.numeric_kind[dtype]():
                            ref column = leaf.numeric[dtype]()
                            for row in range(count):
                                var value = column.value(row)
                                var bits = UInt64(0)
                                if value:
                                    comptime if dtype == DType.float16:
                                        bits = UInt64(
                                            bitcast[DType.uint16](value.value())
                                        )
                                    elif dtype == DType.float32:
                                        bits = UInt64(
                                            bitcast[DType.uint32](value.value())
                                        )
                                    elif dtype == DType.float64:
                                        bits = bitcast[DType.uint64](
                                            value.value()
                                        )
                                    elif dtype.is_signed():
                                        bits = UInt64(Int64(value.value()))
                                    else:
                                        bits = UInt64(value.value())
                                record(buffer, Bool(value), bits)
                                if len(buffer) >= 589824:
                                    file.write_bytes(buffer)
                                    buffer.clear()
            file.write_bytes(buffer)
            print(
                "NODE",
                n,
                node.kind(),
                node.parent(),
                Int(node.nullable()),
                node.fixed_width(),
                count,
                payload,
                hex_bytes(name.as_bytes()),
            )
