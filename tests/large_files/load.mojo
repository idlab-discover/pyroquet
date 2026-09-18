"""Full materialization timer and untimed compact binary validation export."""
from std.sys import argv
from std.time import perf_counter_ns
from std.memory import bitcast
from pyroquet.table_io import load_table


def main() raises:
    var args = argv()
    var names = List[String]()
    for i in range(5, len(args)):
        names.append(args[i])
    var repetitions = Int(args[3])
    for iteration in range(repetitions + 1):
        var start = perf_counter_ns()
        var table = load_table(args[1], names.copy(), Int(args[2]))
        var elapsed = perf_counter_ns() - start
        print("WARMUP" if iteration == 0 else "TIME", elapsed, table.num_rows(), table.num_columns())
        if args[4] != "-":
            var schema = table.schema()
            comptime types = (DType.int8, DType.uint8, DType.int16, DType.uint16, DType.int32, DType.uint32, DType.int64, DType.uint64, DType.float32, DType.float64)
            for c in range(table.num_columns()):
                print("NAME " + table.column(c).name())
                print("COLUMN", c, table.column(c).dtype(), schema.node(c + 1).nullable(), table.column(c).null_count(), table.column(c).size())
                comptime for t in range(len(types)):
                    comptime dtype = types[t]
                    if table.column(c).dtype() == dtype:
                        ref col = table.column(c).numeric[dtype]()
                        var file = open(args[4] + "/" + String(c) + ".bin", "w")
                        var bytes = List[UInt8](capacity=589824)
                        for i in range(col.size()):
                            var value = col.value(i)
                            var bits = UInt64(0)
                            if value:
                                comptime if dtype == DType.float32:
                                    bits = UInt64(bitcast[DType.uint32](value.value()))
                                elif dtype == DType.float64:
                                    bits = bitcast[DType.uint64](value.value())
                                elif dtype.is_signed():
                                    bits = UInt64(Int64(value.value()))
                                else:
                                    bits = UInt64(value.value())
                            bytes.append(UInt8(Bool(value)))
                            comptime for j in range(8):
                                bytes.append(UInt8(bits >> UInt64(j * 8)))
                            if len(bytes) >= 589824:
                                file.write_bytes(bytes)
                                bytes.clear()
                        file.write_bytes(bytes)
