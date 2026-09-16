from std.testing import TestSuite, assert_equal, assert_raises, assert_true
from std.tempfile import TemporaryDirectory
from std.os import listdir
from pyroquet import Schema, SchemaNode, Table, Column
from pyroquet.binary_column import BinaryBuilder, BinaryColumn
from pyroquet.boolean_column import BooleanColumn
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)
from pyroquet.format import inspect_metadata


def _table(count: Int, mode: Int, width: Int = 0) raises -> Table:
    var builder = BinaryBuilder(fixed_width=width)
    var bits = List[UInt8]()
    var valid = List[UInt8]()
    bits.resize(count // 8 + Int(count % 8 != 0), 0)
    valid.resize(len(bits), 0)
    for i in range(count):
        if mode == 0 or (mode == 1 and i % 3 == 0):
            builder.append_null()
        else:
            var bytes = List[UInt8]()
            for j in range(width if width else i % 5):
                bytes.append(UInt8((i * 17 + j) % 256))
            builder.append(Span(bytes))
            valid[i // 8] |= UInt8(1) << UInt8(i % 8)
        if i % 2 == 0:
            bits[i // 8] |= UInt8(1) << UInt8(i % 8)
    var nullable = mode != 2
    var schema = Schema(
        [
            SchemaNode("root", SchemaNode.GROUP, -1),
            SchemaNode("flag", SchemaNode.BOOLEAN, 0, nullable),
            SchemaNode(
                "raw",
                SchemaNode.FIXED_BINARY if width else SchemaNode.BINARY,
                0,
                nullable,
                width,
            ),
        ]
    )
    var columns = List[Column]()
    columns.append(Column("flag", BooleanColumn(count, bits^, valid^)))
    columns.append(Column("raw", builder^.freeze()))
    return Table(schema^, columns^, count)


def test_complete_io_matrix() raises:
    with TemporaryDirectory() as directory:
        var serial = 0
        for count in range(10):
            for mode in range(3):
                for width in [0, 1, 2, 3, 16]:
                    for version in range(1, 3):
                        for codec in range(2):
                            var table = _table(count, mode, width)
                            var path = (
                                directory + "/" + String(serial) + ".parquet"
                            )
                            serial += 1
                            var settings: List[ColumnWriteOptions] = [
                                ColumnWriteOptions(
                                    page_rows=3,
                                    page_version=version,
                                    codec=codec,
                                ),
                                ColumnWriteOptions(
                                    page_rows=2,
                                    page_version=version,
                                    codec=codec,
                                ),
                            ]
                            save_table(
                                path,
                                table,
                                TableWriteOptions(row_group_rows=7),
                                settings,
                            )
                            var loaded = load_table(path)
                            assert_equal(loaded.num_rows(), count)
                            assert_equal(
                                loaded.schema().node(2).fixed_width(), width
                            )
                            for c in range(2):
                                assert_equal(
                                    loaded.column(c).null_count(),
                                    table.column(c).null_count(),
                                )
                            for i in range(count):
                                assert_equal(
                                    loaded.column(0).boolean().value(i),
                                    table.column(0).boolean().value(i),
                                )
                                assert_equal(
                                    loaded.column(1).binary().is_valid(i),
                                    table.column(1).binary().is_valid(i),
                                )
                                if table.column(1).binary().is_valid(i):
                                    var expected = (
                                        table.column(1).binary().value(i)
                                    )
                                    var actual = (
                                        loaded.column(1).binary().value(i)
                                    )
                                    assert_equal(len(actual), len(expected))
                                    for j in range(len(actual)):
                                        assert_equal(actual[j], expected[j])


def test_projection_budget_and_typed_access() raises:
    with TemporaryDirectory() as directory:
        var table = _table(9, 1)
        var path = directory + "/table.parquet"
        save_table(path, table)
        var projection: List[String] = ["raw", "flag"]
        var selected = load_table(path, projection^)
        assert_equal(selected.column(0).name(), "raw")
        with assert_raises():
            _ = selected.column(0).numeric[DType.uint8]()
        with assert_raises():
            _ = selected.column(1).binary()
        with assert_raises():
            _ = selected.column(0).dtype()
        var needed = 4 + 80 + 2 + table.column(1).binary().byte_size()
        var exact = load_table(path, max_output_bytes=needed)
        assert_equal(exact.num_rows(), 9)
        with assert_raises():
            _ = load_table(path, max_output_bytes=needed - 1)


def test_late_oversized_page_cleanup() raises:
    with TemporaryDirectory() as directory:
        var bytes = List[UInt8]()
        bytes.resize(100, 255)
        var table = Table(
            Schema(
                [
                    SchemaNode("root", SchemaNode.GROUP, -1),
                    SchemaNode("raw", SchemaNode.BINARY, 0),
                ]
            ),
            [Column("raw", BinaryColumn([0, 1, 100], bytes^))],
            2,
        )
        var settings: List[ColumnWriteOptions] = [
            ColumnWriteOptions(page_rows=1, max_page_bytes=8)
        ]
        with assert_raises():
            save_table(
                directory + "/late.parquet",
                table,
                TableWriteOptions(),
                settings,
            )
        assert_equal(len(listdir(directory)), 0)


def test_fixed_schema_rejections() raises:
    with assert_raises():
        _ = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("x", SchemaNode.FIXED_BINARY, 0),
            ]
        )
    with assert_raises():
        _ = Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("x", SchemaNode.BINARY, 0, fixed_width=2),
            ]
        )
    with assert_raises():
        _ = Table(
            Schema(
                [
                    SchemaNode("root", SchemaNode.GROUP, -1),
                    SchemaNode("x", SchemaNode.FIXED_BINARY, 0, fixed_width=2),
                ]
            ),
            [Column("x", BinaryColumn([0, 1], [255], fixed_width=1))],
            1,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
