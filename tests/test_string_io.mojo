from std.testing import TestSuite, assert_equal, assert_raises
from std.sys import argv
from std.os import remove
from std.os.path import exists
from pyroquet import Schema, SchemaNode, Table, Column
from pyroquet.string_column import StringBuilder, StringColumn
from pyroquet.binary_column import BinaryColumn
from pyroquet.numeric_column import NumericColumn
from numojo.routines.creation import empty
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)


def _values() -> List[String]:
    return ["", "ASCII", "é", "é", "中文", "😀", "a\0b", "\0", "\U0010ffff"]


def _table(count: Int, mode: Int) raises -> Table:
    var builder = StringBuilder()
    var values = _values()
    for i in range(count):
        if mode == 0 or (mode == 1 and i % 7 == 0):
            builder.append_null()
        else:
            builder.append(values[i % len(values)])
    return Table(
        Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("text", SchemaNode.STRING, 0, mode != 2),
            ]
        ),
        [Column("text", builder^.freeze())],
        count,
    )


def test_string_roundtrip_matrix() raises:
    for directory in [String("build/strings")]:
        for count in [0, 1, 9, 37]:
            for mode in range(3):
                for version in range(1, 3):
                    for codec in range(3):
                        var table = _table(count, mode)
                        var path = directory + "/strings.parquet"
                        if count == 37 and mode == 1:
                            path = (
                                "build/strings/native-v"
                                + String(version)
                                + "-c"
                                + String(codec)
                                + ".parquet"
                            )
                        if exists(path):
                            remove(path)
                        save_table(
                            path,
                            table,
                            TableWriteOptions(row_group_rows=13),
                            [
                                ColumnWriteOptions(
                                    page_rows=4,
                                    page_version=version,
                                    codec=codec,
                                )
                            ],
                        )
                        var loaded = load_table(path)
                        assert_equal(loaded.num_rows(), count)
                        assert_equal(
                            loaded.schema().node(1).kind(), SchemaNode.STRING
                        )
                        assert_equal(loaded.column(0).kind(), SchemaNode.STRING)
                        assert_equal(
                            loaded.column(0).null_count(),
                            table.column(0).null_count(),
                        )
                        for row in range(count):
                            assert_equal(
                                loaded.column(0).string().is_valid(row),
                                table.column(0).string().is_valid(row),
                            )
                            if table.column(0).string().is_valid(row):
                                assert_equal(
                                    loaded.column(0).string().value(row),
                                    table.column(0).string().value(row),
                                )


def test_string_projection_budget_and_type_safety() raises:
    for directory in [String("build/strings")]:
        var table = _table(37, 1)
        var path = directory + "/strings.parquet"
        if exists(path):
            remove(path)
        save_table(path, table)
        var projection: List[String] = ["text"]
        var selected = load_table(path, projection^)
        assert_equal(selected.column(0).name(), "text")
        with assert_raises():
            _ = selected.column(0).binary()
        with assert_raises():
            _ = selected.column(0).numeric[DType.uint8]()
        with assert_raises():
            _ = selected.column(0).string().value(0)
        var needed = 38 * 8 + 5 + table.column(0).string().byte_size()
        var exact = load_table(path, max_output_bytes=needed)
        assert_equal(exact.num_rows(), 37)
        with assert_raises():
            _ = load_table(path, max_output_bytes=needed - 1)
        var binary_table = Table(
            Schema(
                [
                    SchemaNode("root", SchemaNode.GROUP, -1),
                    SchemaNode("raw", SchemaNode.BINARY, 0),
                ]
            ),
            [Column("raw", BinaryColumn([0, 2], [195, 169]))],
            1,
        )
        remove(path)
        save_table(path, binary_table)
        var raw = load_table(path)
        assert_equal(raw.column(0).kind(), SchemaNode.BINARY)
        with assert_raises():
            _ = raw.column(0).string()


def test_mixed_projection_order_and_aggregate_budget() raises:
    var builder = StringBuilder()
    builder.append("é")
    builder.append_null()
    builder.append("")
    var numbers = empty[DType.int32]([3])
    for i in range(3):
        numbers.unsafe_ptr()[unsafe_offset=i] = Int32(i - 1)
    var table = Table(
        Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("text", SchemaNode.STRING, 0, True),
                SchemaNode("n", SchemaNode.INT32, 0),
                SchemaNode("raw", SchemaNode.BINARY, 0),
            ]
        ),
        [
            Column("text", builder^.freeze()),
            Column(NumericColumn[DType.int32](numbers^, [], "n", 0)),
            Column("raw", BinaryColumn([0, 1, 1, 2], [255, 128])),
        ],
        3,
    )
    var path = String("build/strings/mixed.parquet")
    if exists(path):
        remove(path)
    save_table(path, table)
    var projection: List[String] = ["raw", "text", "n"]
    var loaded = load_table(path, projection^)
    assert_equal(loaded.column(0).name(), "raw")
    assert_equal(loaded.column(1).string().value(0), "é")
    assert_equal(
        loaded.column(2).numeric[DType.int32]().value(2).value(), Int32(1)
    )
    # Each variable-width column: four offsets + validity byte + two payload bytes.
    # Required numeric output: three int32 values, no validity allocation.
    var exact = load_table(path, max_output_bytes=82)
    assert_equal(exact.num_rows(), 3)
    with assert_raises():
        _ = load_table(path, max_output_bytes=81)


def main() raises:
    var args = argv()
    if len(args) > 1:
        var table = load_table(args[1])
        assert_equal(table.num_columns(), 1)
        print("rows", table.num_rows(), "kind", table.column(0).kind())
        for row in range(table.num_rows()):
            if not table.column(0).string().is_valid(row):
                print("null")
            else:
                var value = table.column(0).string().value(row)
                var line = String("bytes")
                for byte in value.as_bytes():
                    line += " " + String(Int(byte))
                print(line)
    else:
        TestSuite.discover_tests[__functions_in_module()]().run()
