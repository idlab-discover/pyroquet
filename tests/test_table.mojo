from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from numojo.routines.creation import empty
from pyroquet.numeric_column import NumericColumn
from pyroquet import (
    Column,
    Schema,
    SchemaNode,
    Table,
)


def flat_schema(nullable: Bool = True) raises -> Schema:
    return Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("value", SchemaNode.UINT32, 0, nullable),
        ]
    )


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
                single_column[DType.uint32]("a"),
                single_column[DType.uint32]("b"),
                single_column[DType.uint32]("a.b"),
            ],
            1,
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
        _ = Table(flat_schema(), List[Column](), 0)
    with assert_raises():
        _ = Table(flat_schema(), [single_column[DType.uint32]("value")], -1)
    var values = empty[DType.uint32]([0])
    var zero_rows = Table(
        flat_schema(),
        [Column(NumericColumn(values^, List[UInt8](), "value", 0))],
        0,
    )
    assert_equal(zero_rows.num_rows(), 0)
    assert_equal(zero_rows.num_columns(), 1)
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
