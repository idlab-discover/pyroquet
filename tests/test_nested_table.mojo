from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from numojo.routines.creation import empty
from pyroquet import Schema, SchemaNode, Column
from pyroquet.numeric_column import NumericColumn
from pyroquet.binary_column import BinaryColumn
from pyroquet.nested_table import NestedTable, NestedStructure


def make_table() raises -> NestedTable:
    var nodes: List[SchemaNode] = [
        SchemaNode("schema", SchemaNode.GROUP, -1),
        SchemaNode("s", SchemaNode.GROUP, 0, True),
        SchemaNode("l", SchemaNode.LIST, 1, True),
        SchemaNode("element", SchemaNode.INT32, 2, True),
    ]
    var values = empty[DType.int32]([2])
    values.unsafe_ptr()[unsafe_offset=0] = 42
    values.unsafe_ptr()[unsafe_offset=1] = 0
    var leaf = Column(NumericColumn(values^, [UInt8(1)], "element", 1))
    # Absent struct; present struct/null list; empty list; [42, null].
    return NestedTable(
        Schema(nodes^),
        [leaf^],
        [
            NestedStructure(4, [UInt8(14)]),
            NestedStructure(4, [UInt8(12)], [0, 0, 0, 0, 2]),
        ],
        4,
    )


def test_nested_distinctions() raises:
    var table = make_table()
    assert_equal(table.num_rows(), 4)
    assert_equal(table.num_leaves(), 1)
    assert_false(table.structure(1).is_valid(0))
    assert_true(table.structure(1).is_valid(1))
    assert_false(table.structure(2).is_valid(1))
    assert_true(table.structure(2).is_valid(2))
    assert_equal(table.structure(2).offset(2), table.structure(2).offset(3))
    assert_equal(table.structure(2).child_count(), 2)
    assert_equal(
        table.leaf(table.leaf_index(3)).numeric[DType.int32]().value(0).value(),
        42,
    )
    assert_false(Bool(table.leaf(0).numeric[DType.int32]().value(1)))


def test_bad_structures() raises:
    with assert_raises():
        var s = NestedStructure(2, [UInt8(255)])
    with assert_raises():
        var s = NestedStructure(2, [], [0, 2, 1])
    with assert_raises():
        var s = NestedStructure(1, [UInt8(0)], [0, 1])
    with assert_raises():
        var s = NestedStructure(1, [], [1, 1])
    with assert_raises():
        var s = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("l", SchemaNode.LIST, 0),
            ]
        )
    with assert_raises():
        var s = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("l", SchemaNode.LIST, 0),
                SchemaNode("element", SchemaNode.GROUP, 1),
            ]
        )


def test_required_and_parent_validity() raises:
    with assert_raises():
        var schema = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("s", SchemaNode.GROUP, 0),
            ]
        )
        var table = NestedTable(
            schema^, [], [NestedStructure(1, [UInt8(0)])], 1
        )
    with assert_raises():
        var schema = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("s", SchemaNode.GROUP, 0, True),
                SchemaNode("x", SchemaNode.INT32, 1),
            ]
        )
        var values = empty[DType.int32]([1])
        values.unsafe_ptr()[unsafe_offset=0] = 7
        var leaf = Column(NumericColumn(values^, List[UInt8](), "x", 0))
        var table = NestedTable(
            schema^, [leaf^], [NestedStructure(1, [UInt8(0)])], 1
        )


def test_binary_validity_is_not_length() raises:
    var schema = Schema(
        [
            SchemaNode("root", SchemaNode.GROUP, -1),
            SchemaNode("s", SchemaNode.GROUP, 0, True),
            SchemaNode("b", SchemaNode.BINARY, 1, True),
        ]
    )
    var leaf = Column("b", BinaryColumn([0, 0, 0], [], [UInt8(2)]))
    var table = NestedTable(
        schema^, [leaf^], [NestedStructure(2, [UInt8(2)])], 2
    )
    assert_false(table.leaf(0).binary().is_valid(0))
    assert_true(table.leaf(0).binary().is_valid(1))
    assert_equal(len(table.leaf(0).binary().value(1)), 0)


def test_noncanonical_logical_element_name() raises:
    with assert_raises():
        var schema = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("l", SchemaNode.LIST, 0),
                SchemaNode("x", SchemaNode.INT32, 1),
            ]
        )
        var values = empty[DType.int32]([0])
        var leaf = Column(NumericColumn(values^, List[UInt8](), "x", 0))
        var table = NestedTable(
            schema^, [leaf^], [NestedStructure(0, [], [0])], 0
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
