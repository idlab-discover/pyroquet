"""Mixed writing retains schema, independent page ranges and atomic publication."""
from std.os import listdir
from temp_directory import TestDirectory
from std.testing import assert_equal, assert_raises, TestSuite
from numojo.routines.creation import empty
from pyroquet.schema import Schema, SchemaNode
from pyroquet.table import Table, Column
from pyroquet.numojo_io import NumericColumn, load_numeric
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)
from pyroquet.format import inspect_metadata, inspect_column_pages


def _mixed(rows: Int, nullable: Bool = True) raises -> Table:
    var nodes = List[SchemaNode]()
    nodes.append(SchemaNode("root", SchemaNode.GROUP, -1))
    nodes.append(SchemaNode("a.b", SchemaNode.INT64, 0, False))
    nodes.append(SchemaNode("unsigned", SchemaNode.UINT64, 0, nullable))
    var left = empty[DType.int64]([rows])
    var right = empty[DType.uint64]([rows])
    for i in range(rows):
        left.unsafe_ptr()[unsafe_offset=i] = Int64(-i - 1)
        right.unsafe_ptr()[unsafe_offset=i] = UInt64.MAX - UInt64(i)
    var columns = List[Column]()
    columns.append(
        Column(NumericColumn[DType.int64](left^, List[UInt8](), "a.b", 0))
    )
    columns.append(
        Column(
            NumericColumn[DType.uint64](right^, List[UInt8](), "unsigned", 0)
        )
    )
    return Table(Schema(nodes^), columns^, rows)


def test_mixed_independent_pages() raises:
    with TestDirectory() as directory:
        var table = _mixed(11)
        var settings: List[ColumnWriteOptions] = [
            ColumnWriteOptions(page_rows=2, page_version=1, codec=0),
            ColumnWriteOptions(page_rows=3, page_version=2, codec=1),
        ]
        var path = directory + "/mixed.parquet"
        save_table(path, table, TableWriteOptions(row_group_rows=7), settings)
        var metadata = inspect_metadata(path)
        assert_equal(len(metadata.row_groups), 2)
        assert_equal(metadata.schema[1].repetition, 0)
        assert_equal(metadata.schema[2].repetition, 1)
        assert_equal(len(inspect_column_pages(path, 0, 0)), 4)
        assert_equal(len(inspect_column_pages(path, 0, 1)), 3)
        var left = load_numeric[DType.int64](path, "a.b")
        var right = load_numeric[DType.uint64](path, "unsigned")
        for i in range(11):
            assert_equal(left.value(i).value(), Int64(-i - 1))
            assert_equal(right.value(i).value(), UInt64.MAX - UInt64(i))
        assert_equal(table.column(0).numeric[DType.int64]().size(), 11)


def test_table_footer_failure_and_collision() raises:
    with TestDirectory() as directory:
        var table = _mixed(3)
        var path = directory + "/mixed.parquet"
        with assert_raises():
            save_table(path, table, TableWriteOptions(max_metadata_bytes=1))
        assert_equal(len(listdir(directory)), 0)
        with assert_raises():
            save_table(
                path,
                table,
                TableWriteOptions(row_group_rows=1, max_column_chunks=5),
            )
        assert_equal(len(listdir(directory)), 0)
        save_table(path, table)
        var file = open(path, "r")
        var before = file.read_bytes()
        file.close()
        with assert_raises():
            save_table(path, table)
        file = open(path, "r")
        assert_equal(file.read_bytes(), before)
        file.close()
        assert_equal(len(listdir(directory)), 1)


def test_late_column_failure_cleans_staging() raises:
    with TestDirectory() as directory:
        var table = _mixed(1, False)
        var settings: List[ColumnWriteOptions] = [
            ColumnWriteOptions(),
            ColumnWriteOptions(page_rows=1, codec=1, max_page_bytes=7),
        ]
        # First column succeeds; the second eight-byte scalar exceeds its
        # seven-byte raw-page bound. Repeated 0xff bytes can compress below
        # eight bytes, so compressed size is not a reliable failure trigger.
        with assert_raises():
            save_table(
                directory + "/late.parquet",
                table,
                TableWriteOptions(),
                settings,
            )
        assert_equal(len(listdir(directory)), 0)


def test_empty_table_schema() raises:
    with TestDirectory() as directory:
        var table = _mixed(0)
        var path = directory + "/empty.parquet"
        save_table(path, table)
        var metadata = inspect_metadata(path)
        assert_equal(len(metadata.schema), 3)
        assert_equal(len(metadata.row_groups), 0)
        assert_equal(metadata.schema[2].repetition, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
