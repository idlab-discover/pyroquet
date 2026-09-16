from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from numojo.routines.creation import empty
from pyroquet.numeric_column import NumericColumn
from pyroquet import (
    Column,
    Schema,
    SchemaNode,
    Table,
    UInt32Chunk,
    UInt32Column,
)


def flat_schema(nullable: Bool = True) raises -> Schema:
    return Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("value", SchemaNode.UINT32, 0, nullable),
        ]
    )


def retained_column() raises -> UInt32Column:
    var column = UInt32Column(
        [
            UInt32Chunk([0, 2147483647, 0], [UInt8(3)]),
            UInt32Chunk([2147483648, UInt32.MAX, 1]),
            UInt32Chunk(List[UInt32]()),
            UInt32Chunk([0], [UInt8(0)]),
        ]
    )
    return column^


def test_nullable_extrema_and_retained_column() raises:
    var column = retained_column()
    assert_equal(len(column), 7)
    assert_equal(column.num_chunks(), 4)
    assert_equal(column.null_count(), 2)
    assert_equal(column.value(0).value(), UInt32(0))
    assert_equal(column.value(1).value(), UInt32(2147483647))
    assert_true(not column.value(2))
    assert_equal(column.value(3).value(), UInt32(2147483648))
    assert_equal(column.value(4).value(), UInt32.MAX)
    assert_equal(column.value(5).value(), UInt32(1))
    assert_true(not column.value(6))
    with assert_raises():
        _ = column.value(7)
    with assert_raises():
        _ = column.value(-1)
    with assert_raises():
        _ = column.chunk(4)


def test_independent_chunks_and_zero_column_rows() raises:
    var schema = Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("a", SchemaNode.UINT32, 0),
            SchemaNode("b", SchemaNode.UINT32, 0),
        ]
    )
    var table = Table(
        schema^,
        [
            UInt32Column([UInt32Chunk([1]), UInt32Chunk([2, 3])]),
            UInt32Column([UInt32Chunk([4, 5, 6])]),
        ],
        3,
    )
    assert_equal(table.column(0).value(2).value(), UInt32(3))
    assert_equal(table.column(1).value(2).value(), UInt32(6))
    assert_equal(table.num_columns(), 2)
    var empty_projection = Table(
        Schema([SchemaNode("schema", SchemaNode.GROUP, -1)]),
        List[UInt32Column](),
        17,
    )
    assert_equal(empty_projection.num_columns(), 0)
    assert_equal(empty_projection.num_rows(), 17)
    var empty = Table(flat_schema(), [UInt32Column(List[UInt32Chunk]())], 0)
    assert_equal(empty.num_rows(), 0)


def test_nullable_bitmap_shape() raises:
    var chunk = UInt32Chunk([0, 0, 0, 0, 0, 0, 0, 0, 42], [UInt8(0), 1])
    assert_equal(chunk.null_count(), 8)
    assert_equal(chunk.value(8).value(), UInt32(42))
    with assert_raises():
        _ = UInt32Chunk([1], [UInt8(1), 0])
    with assert_raises():
        _ = UInt32Chunk([1], [UInt8(255)])
    with assert_raises():
        _ = UInt32Chunk(List[UInt32](), [UInt8(0)])
    with assert_raises():
        _ = chunk.value(9)


def test_table_shape_and_required_field() raises:
    with assert_raises():
        _ = Table(
            flat_schema(False),
            [UInt32Column([UInt32Chunk([0], [UInt8(0)])])],
            1,
        )
    with assert_raises():
        _ = Table(flat_schema(), [UInt32Column([UInt32Chunk([1])])], 2)
    with assert_raises():
        _ = Table(flat_schema(), List[UInt32Column](), 0)
    with assert_raises():
        _ = Table(flat_schema(), [UInt32Column(List[UInt32Chunk]())], -1)


def test_schema_hierarchy_and_literal_dots() raises:
    var schema = Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("a", SchemaNode.GROUP, 0, True),
            SchemaNode("b", SchemaNode.UINT32, 1),
            SchemaNode("a.b", SchemaNode.UINT32, 0),
        ]
    )
    assert_equal(schema.node(2).parent(), 1)
    assert_equal(schema.node(3).parent(), 0)
    assert_equal(schema.node(3).name(), "a.b")
    var shared = schema.copy()
    assert_true(shared.node(1).nullable())
    with assert_raises():
        _ = Table(
            schema^,
            [
                UInt32Column(List[UInt32Chunk]()),
                UInt32Column(List[UInt32Chunk]()),
                UInt32Column(List[UInt32Chunk]()),
            ],
            0,
        )


def test_invalid_schema() raises:
    with assert_raises():
        _ = Schema(List[SchemaNode]())
    with assert_raises():
        _ = Schema([SchemaNode("root", SchemaNode.UINT32, -1)])
    with assert_raises():
        _ = Schema([SchemaNode("root", SchemaNode.GROUP, -1, True)])
    with assert_raises():
        _ = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("x", SchemaNode.UINT32, 1),
            ]
        )
    with assert_raises():
        _ = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("x", SchemaNode.UINT32, 0),
                SchemaNode("child", SchemaNode.UINT32, 1),
            ]
        )
    with assert_raises():
        _ = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("x", SchemaNode.UINT32, 0),
                SchemaNode("x", SchemaNode.UINT32, 0),
            ]
        )
    with assert_raises():
        _ = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("x", 999, 0),
            ]
        )
    with assert_raises():
        _ = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("a", SchemaNode.GROUP, 0),
                SchemaNode("b", SchemaNode.UINT32, 1),
            ],
            max_depth=1,
        )


def test_mixed_numeric_borrows() raises:
    comptime dtypes = (
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
    var nodes: List[SchemaNode] = [SchemaNode("root", SchemaNode.GROUP, -1)]
    var columns = List[Column]()
    var value_addresses = List[Int]()
    var validity_addresses = List[Int]()
    comptime for i in range(len(dtypes)):
        comptime dtype = dtypes[i]
        var name = String(i)
        nodes.append(
            SchemaNode(name, SchemaNode.numeric_kind[dtype](), 0, True)
        )
        var values = empty[dtype]([3])
        values.unsafe_ptr()[unsafe_offset=0] = Scalar[dtype].MAX
        values.unsafe_ptr()[unsafe_offset=1] = 0
        values.unsafe_ptr()[unsafe_offset=2] = Scalar[dtype].MIN
        var validity: List[UInt8] = [5]
        # Preserve only integer addresses across moves, never escaped pointers.
        value_addresses.append(Int(values.unsafe_ptr()))
        validity_addresses.append(Int(Span(validity).unsafe_ptr()))
        columns.append(Column(NumericColumn(values^, validity^, name, 1)))
    var owner = Table(Schema(nodes^), columns^, 3)
    var table = owner^
    assert_equal(table.num_rows(), 3)
    assert_equal(table.num_columns(), 10)
    comptime for i in range(len(dtypes)):
        comptime dtype = dtypes[i]
        assert_equal(
            Int(table.column(i).numeric[dtype]().values().unsafe_ptr()),
            value_addresses[i],
        )
        assert_equal(
            Int(table.column(i).numeric[dtype]().validity().unsafe_ptr()),
            validity_addresses[i],
        )
        assert_equal(table.column(i).dtype(), dtype)
        assert_equal(table.column(i).name(), String(i))
        assert_equal(table.schema().node(i + 1).dtype(), dtype)
        assert_true(table.schema().node(i + 1).nullable())
        assert_equal(
            table.column(i).numeric[dtype]().value(0).value(), Scalar[dtype].MAX
        )
        assert_true(not table.column(i).numeric[dtype]().value(1))
        assert_equal(
            table.column(i).numeric[dtype]().value(2).value(), Scalar[dtype].MIN
        )
        assert_equal(table.column(i).null_count(), 1)
    with assert_raises():
        _ = table.column(0).numeric[DType.uint64]().size()
    with assert_raises():
        _ = table.column(-1).size()
    with assert_raises():
        _ = table.column(10).size()


def single_column[
    dtype: DType
](name: String, nullable: Bool = False) raises -> Column:
    var values = empty[dtype]([1])
    values.unsafe_ptr()[unsafe_offset=0] = 0
    var validity = List[UInt8]()
    if nullable:
        validity.append(0)
    return Column(NumericColumn(values^, validity^, name, Int(nullable)))


def test_mixed_schema_invariants() raises:
    with assert_raises():
        _ = Table(flat_schema(), [single_column[DType.uint32]("wrong")], 1)
    with assert_raises():
        _ = Table(flat_schema(), [single_column[DType.int32]("value")], 1)
    with assert_raises():
        _ = Table(flat_schema(), [single_column[DType.uint32]("value")], 2)
    with assert_raises():
        _ = Table(
            flat_schema(False), [single_column[DType.uint32]("value", True)], 1
        )
    var table = Table(
        flat_schema(), [single_column[DType.uint32]("value", True)], 1
    )
    assert_true(not table.column(0).numeric[DType.uint32]().value(0))
    var empty = Table(
        Schema([SchemaNode("root", SchemaNode.GROUP, -1)]), List[Column](), 123
    )
    assert_equal(empty.num_rows(), 123)
    assert_equal(empty.num_columns(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
