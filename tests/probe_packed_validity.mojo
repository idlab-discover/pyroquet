"""Consumer probe with explicit storage checks active in both assertion modes."""
from std.sys import argv
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)
from pyroquet.schema import SchemaNode


def main() raises:
    var args = argv()
    var table = load_table(args[1])
    print("rows", table.num_rows())
    for c in range(table.num_columns()):
        ref column = table.column(c)
        print(
            "column",
            column.name(),
            column.kind(),
            table.schema().node(c + 1).fixed_width(),
        )
        var count = table.num_rows()
        var nulls = 0
        var expected_bitmap = List[UInt8]()
        for _ in range((count + 7) // 8):
            expected_bitmap.append(0)
        for i in range(count):
            var valid = False
            if column.kind() == SchemaNode.BOOLEAN:
                ref boolean = column.boolean()
                valid = Bool(boolean.value(i))
                if not valid and (boolean._values[i // 8] & (UInt8(1) << UInt8(i % 8))) != 0:
                    raise Error("Boolean null storage is nonzero")
            elif column.kind() == SchemaNode.BINARY or column.kind() == SchemaNode.FIXED_BINARY:
                ref binary = column.binary()
                valid = binary.is_valid(i)
                if not valid and binary._offsets[i] != binary._offsets[i + 1]:
                    raise Error("Binary null offsets differ")
            else:
                ref numeric = column.numeric[DType.int32]()
                valid = Bool(numeric.value(i))
                # i is a logical row, strictly below the allocation's count.
                if not valid and numeric.values().unsafe_ptr()[unsafe_offset=i] != 0:
                    raise Error("Numeric null storage is nonzero")
            if valid:
                expected_bitmap[i // 8] |= UInt8(1) << UInt8(i % 8)
            else:
                nulls += 1
        for i in range(len(expected_bitmap)):
            var actual = UInt8(255)
            if i == len(expected_bitmap) - 1 and count % 8 != 0:
                actual = (UInt8(1) << UInt8(count % 8)) - 1
            if column.kind() == SchemaNode.BOOLEAN:
                if len(column.boolean()._validity) != 0:
                    actual = column.boolean()._validity[i]
            elif column.kind() == SchemaNode.BINARY or column.kind() == SchemaNode.FIXED_BINARY:
                if len(column.binary()._validity) != 0:
                    actual = column.binary()._validity[i]
            else:
                if len(column.numeric[DType.int32]().validity()) != 0:
                    actual = column.numeric[DType.int32]().validity()[i]
            if actual != expected_bitmap[i]:
                raise Error("Validity bits or padding differ")
        if column.kind() == SchemaNode.BOOLEAN:
            if column.boolean().null_count() != nulls:
                raise Error("Boolean null count differs")
            if count % 8 != 0 and column.boolean()._values[count // 8] >> UInt8(count % 8) != 0:
                raise Error("Boolean value padding is nonzero")
        elif column.kind() == SchemaNode.BINARY or column.kind() == SchemaNode.FIXED_BINARY:
            if column.binary().null_count() != nulls:
                raise Error("Binary null count differs")
        elif column.numeric[DType.int32]().null_count() != nulls:
            raise Error("Numeric null count differs")
        for i in range(table.num_rows()):
            if column.kind() == SchemaNode.BOOLEAN:
                var value = column.boolean().value(i)
                if value:
                    print(Int(value.value()))
                else:
                    print("null")
            elif (
                column.kind() == SchemaNode.BINARY
                or column.kind() == SchemaNode.FIXED_BINARY
            ):
                if not column.binary().is_valid(i):
                    print("null")
                else:
                    var bytes = column.binary().value(i)
                    var line = String("bytes")
                    for byte in bytes:
                        line += " " + String(Int(byte))
                    print(line)
            else:
                var value = column.numeric[DType.int32]().value(i)
                if value:
                    print(Int(value.value()))
                else:
                    print("null")
