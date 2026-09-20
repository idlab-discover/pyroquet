"""Exercise the precompiled package rather than resolving the library source."""
from std.testing import assert_equal
from numojo.routines.creation import empty
from pyroquet import Column, EnumBuilder, Schema, SchemaNode, Table
from pyroquet.numeric_column import NumericColumn


def main() raises:
    var values = empty[DType.float16]([2])
    values.fill(1)
    var table = Table(
        Schema(
            [
                SchemaNode("schema", SchemaNode.GROUP, -1),
                SchemaNode("half", SchemaNode.FLOAT16, 0),
            ]
        ),
        [Column(NumericColumn(values^, List[UInt8](), "half", 0))],
        2,
    )
    var shared = table.values_mut[DType.float16](0)
    shared.fill(3)
    assert_equal(table.column(0).numeric[DType.float16]().value(1).value(), 3)
    var builder = EnumBuilder(2)
    builder.append("ready")
    builder.append("checked")
    var enumeration = builder^.freeze()
    enumeration.set_index(0, 1)
    assert_equal(enumeration.value(0), "checked")
    print(
        "Precompiled package: FLOAT16 shared mutation and checked ENUM passed"
    )
