from std.testing import assert_equal, assert_false, assert_raises, TestSuite
from std.os import remove
from std.pathlib import Path
from test_nested_table import make_table
from numojo.routines.creation import empty
from pyroquet import (
    Schema,
    SchemaNode,
    Column,
)
from pyroquet.numeric_column import NumericColumn
from pyroquet.boolean_column import BooleanColumn
from pyroquet.binary_column import BinaryColumn
from pyroquet.nested_table import NestedTable, NestedStructure
from pyroquet.format import inspect_metadata, inspect_column_pages
from pyroquet.nested_write import save_nested_table
from pyroquet.table_write import TableWriteOptions, ColumnWriteOptions


def test_write_nested() raises:
    var table = make_table()
    for version in range(1, 3):
        for codec in range(3):
            var path = (
                "build/nested-write-v"
                + String(version)
                + "-c"
                + String(codec)
                + ".parquet"
            )
            if Path(path).exists():
                remove(path)
            save_nested_table(
                path,
                table,
                TableWriteOptions(row_group_rows=3),
                [
                    ColumnWriteOptions(
                        page_rows=2, page_version=version, codec=codec
                    )
                ],
            )


def test_failed_write_does_not_publish() raises:
    var table = make_table()
    var path = "build/nested-write-too-small.parquet"
    if Path(path).exists():
        remove(path)
    with assert_raises():
        save_nested_table(
            path,
            table,
            column_options=[ColumnWriteOptions(page_rows=1, max_page_bytes=8)],
        )
    assert_false(Path(path).exists())


def all_leaves() raises -> NestedTable:
    var nodes: List[SchemaNode] = [
        SchemaNode("schema", SchemaNode.GROUP, -1),
        SchemaNode("s", SchemaNode.GROUP, 0),
    ]
    var leaves = List[Column]()
    var structures: List[NestedStructure] = [NestedStructure(4)]
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
    comptime for t in range(10):
        comptime dtype = types[t]
        var list_index = len(nodes)
        nodes.append(SchemaNode("n" + String(t), SchemaNode.LIST, 1, True))
        nodes.append(
            SchemaNode(
                "element", SchemaNode.numeric_kind[dtype](), list_index, True
            )
        )
        structures.append(NestedStructure(4, [UInt8(14)], [0, 0, 0, 1, 3]))
        var values = empty[dtype]([3])
        values.unsafe_ptr()[unsafe_offset=0] = 1
        values.unsafe_ptr()[unsafe_offset=1] = 0
        values.unsafe_ptr()[unsafe_offset=2] = 2
        leaves.append(Column(NumericColumn(values^, [UInt8(5)], "element", 1)))
    var kinds: List[Int] = [
        SchemaNode.BOOLEAN,
        SchemaNode.BINARY,
        SchemaNode.FIXED_BINARY,
    ]
    for k in range(3):
        var list_index = len(nodes)
        nodes.append(SchemaNode("b" + String(k), SchemaNode.LIST, 1, True))
        nodes.append(
            SchemaNode(
                "element", kinds[k], list_index, True, 2 if k == 2 else 0
            )
        )
        structures.append(NestedStructure(4, [UInt8(14)], [0, 0, 0, 1, 3]))
    leaves.append(Column("element", BooleanColumn(3, [UInt8(4)], [UInt8(5)])))
    leaves.append(
        Column(
            "element",
            BinaryColumn([0, 0, 0, 2], [UInt8(0), UInt8(255)], [UInt8(5)]),
        )
    )
    leaves.append(
        Column(
            "element",
            BinaryColumn(
                [0, 2, 2, 4],
                [UInt8(1), UInt8(2), UInt8(255), UInt8(0)],
                [UInt8(5)],
                2,
            ),
        )
    )
    return NestedTable(Schema(nodes^), leaves^, structures^, 4)


def test_all_primitive_lists() raises:
    var table = all_leaves()
    for version in range(1, 3):
        var path = "build/nested-write-all-v" + String(version) + ".parquet"
        if Path(path).exists():
            remove(path)
        var settings = List[ColumnWriteOptions]()
        for i in range(table.num_leaves()):
            settings.append(
                ColumnWriteOptions(
                    page_rows=1 + i % 3, page_version=version, codec=i % 3
                )
            )
        save_nested_table(
            path, table, TableWriteOptions(row_group_rows=3), settings
        )
        var metadata = inspect_metadata(path)
        assert_equal(len(metadata.row_groups), 2)
        assert_equal(metadata.num_rows, 4)
        assert_equal(len(metadata.row_groups[0].columns), 13)


def test_required_and_empty() raises:
    for rows in range(4):
        var nodes: List[SchemaNode] = [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("a.b", SchemaNode.LIST, 0),
            SchemaNode("element", SchemaNode.INT64, 1),
        ]
        var values = empty[DType.int64]([rows])
        var offsets: List[Int] = [0]
        for i in range(rows):
            values.unsafe_ptr()[unsafe_offset=i] = Int64(i)
            offsets.append(i + 1)
        var leaf = Column(NumericColumn(values^, List[UInt8](), "element", 0))
        var table = NestedTable(
            Schema(nodes^),
            [leaf^],
            [NestedStructure(rows, List[UInt8](), offsets^)],
            rows,
        )
        var path = "build/nested-write-required-" + String(rows) + ".parquet"
        if Path(path).exists():
            remove(path)
        save_nested_table(path, table)
        assert_equal(inspect_metadata(path).num_rows, Int64(rows))


def test_struct_independent_pages_non_dfs() raises:
    var schema = Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("s", SchemaNode.GROUP, 0, True),
            SchemaNode("literal.dot", SchemaNode.INT32, 0),
            SchemaNode("x", SchemaNode.INT32, 1),
        ]
    )
    var literal = empty[DType.int32]([3])
    var child = empty[DType.int32]([3])
    for i in range(3):
        literal.unsafe_ptr()[unsafe_offset=i] = Int32(i + 10)
        child.unsafe_ptr()[unsafe_offset=i] = Int32(i + 20)
    var a = Column(NumericColumn(literal^, List[UInt8](), "literal.dot", 0))
    var b = Column(NumericColumn(child^, [UInt8(6)], "x", 1))
    var table = NestedTable(
        schema^, [a^, b^], [NestedStructure(3, [UInt8(6)])], 3
    )
    var path = "build/nested-write-struct.parquet"
    if Path(path).exists():
        remove(path)
    save_nested_table(
        path,
        table,
        column_options=[
            ColumnWriteOptions(page_rows=2),
            ColumnWriteOptions(page_rows=1, page_version=2),
        ],
    )
    var metadata = inspect_metadata(path)
    assert_equal(metadata.schema[2].name, "x")
    assert_equal(metadata.schema[3].name, "literal.dot")
    assert_equal(len(inspect_column_pages(path, 0, 0)), 3)
    assert_equal(len(inspect_column_pages(path, 0, 1)), 2)


def test_long_list_and_child_bound() raises:
    var n = 10000
    var schema = Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("l", SchemaNode.LIST, 0),
            SchemaNode("element", SchemaNode.BOOLEAN, 1),
        ]
    )
    var bits = List[UInt8]()
    bits.resize(n // 8, 85)
    var leaf = Column("element", BooleanColumn(n, bits^))
    var table = NestedTable(
        schema^, [leaf^], [NestedStructure(3, List[UInt8](), [0, 0, n, n])], 3
    )
    var path = "build/nested-write-long.parquet"
    if Path(path).exists():
        remove(path)
    save_nested_table(
        path,
        table,
        column_options=[ColumnWriteOptions(page_rows=1, page_version=2)],
    )
    var pages = inspect_column_pages(path, 0, 0)
    assert_equal(len(pages), 3)
    var fail = "build/nested-write-too-small.parquet"
    with assert_raises():
        save_nested_table(
            fail,
            table,
            column_options=[ColumnWriteOptions(page_rows=1, max_page_bytes=32)],
        )
    assert_false(Path(fail).exists())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
