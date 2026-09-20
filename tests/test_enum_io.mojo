from std.testing import TestSuite, assert_equal, assert_raises
from std.sys import argv
from std.os import remove
from std.os.path import exists
from pyroquet import Schema, SchemaNode, Table, Column
from pyroquet.enum_column import EnumBuilder, EnumColumn
from pyroquet.string_column import StringBuilder
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
    var builder = EnumBuilder(count)
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
                SchemaNode("text", SchemaNode.ENUM, 0, mode != 2),
            ]
        ),
        [Column("text", builder^.freeze())],
        count,
    )


def test_enum_roundtrip_matrix() raises:
    for count in [0, 1, 9, 37]:
        for mode in range(3):
            for version in range(1, 3):
                for codec in [0, 1, 2, 6]:
                    var table = _table(count, mode)
                    var path = String("build/enums/roundtrip.parquet")
                    if count == 37 and mode == 1:
                        path = (
                            "build/enums/native-v"
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
                                page_rows=4, page_version=version, codec=codec
                            )
                        ],
                    )
                    var loaded = load_table(path)
                    assert_equal(loaded.num_rows(), count)
                    assert_equal(
                        loaded.schema().node(1).kind(), SchemaNode.ENUM
                    )
                    assert_equal(loaded.column(0).kind(), SchemaNode.ENUM)
                    assert_equal(
                        loaded.column(0).null_count(),
                        table.column(0).null_count(),
                    )
                    for row in range(count):
                        assert_equal(
                            loaded.column(0).enumeration().is_valid(row),
                            table.column(0).enumeration().is_valid(row),
                        )
                        if table.column(0).enumeration().is_valid(row):
                            assert_equal(
                                loaded.column(0).enumeration().value(row),
                                table.column(0).enumeration().value(row),
                            )


def test_enum_projection_budget_and_type_safety() raises:
    var path = String("build/enums/projection.parquet")
    if exists(path):
        remove(path)
    var table = _table(37, 1)
    save_table(path, table)
    var names: List[String] = ["text"]
    var projected = load_table(path, names^)
    assert_equal(projected.column(0).name(), "text")
    assert_equal(projected.column(0).enumeration().value(1), "ASCII")
    with assert_raises():
        _ = projected.column(0).string()
    with assert_raises():
        _ = projected.column(0).binary()
    with assert_raises():
        _ = projected.column(0).numeric[DType.uint32]()
    with assert_raises():
        _ = projected.column(0).enumeration().value(0)
    with assert_raises():
        _ = load_table(path, max_output_bytes=1)
    var needed = table.column(0).enumeration().storage_byte_size()
    var exact = load_table(path, max_output_bytes=needed)
    assert_equal(exact.num_rows(), 37)
    with assert_raises():
        _ = load_table(path, max_output_bytes=needed - 1)
    var control = load_table("build/enums/dictionary-string-control.parquet")
    assert_equal(control.column(0).kind(), SchemaNode.STRING)
    with assert_raises():
        _ = control.column(0).enumeration()


def test_mixed_enum_projection_and_aggregate_budget() raises:
    var enum_builder = EnumBuilder(3)
    var text_builder = StringBuilder()
    enum_builder.append("é")
    enum_builder.append_null()
    enum_builder.append("")
    text_builder.append("é")
    text_builder.append_null()
    text_builder.append("")
    var numbers = empty[DType.int32]([3])
    for i in range(3):
        numbers.unsafe_ptr()[unsafe_offset=i] = Int32(i - 1)
    var table = Table(
        Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("enum", SchemaNode.ENUM, 0, True),
                SchemaNode("text", SchemaNode.STRING, 0, True),
                SchemaNode("n", SchemaNode.INT32, 0),
            ]
        ),
        [
            Column("enum", enum_builder^.freeze()),
            Column("text", text_builder^.freeze()),
            Column(NumericColumn[DType.int32](numbers^, [], "n", 0)),
        ],
        3,
    )
    var path = String("build/enums/mixed.parquet")
    if exists(path):
        remove(path)
    save_table(path, table)
    var names: List[String] = ["n", "text", "enum"]
    # ENUM: 12 indices + 1 validity + 24 offsets + 2 payload = 39.
    # STRING: 32 offsets + 1 validity + 2 payload = 35. Numeric: 12.
    var loaded = load_table(path, names^, max_output_bytes=86)
    assert_equal(loaded.column(0).name(), "n")
    assert_equal(
        loaded.column(0).numeric[DType.int32]().value(2).value(), Int32(1)
    )
    assert_equal(loaded.column(1).string().value(0), "é")
    assert_equal(loaded.column(2).enumeration().value(2), "")
    assert_equal(loaded.column(2).enumeration().is_valid(1), False)
    with assert_raises():
        _ = load_table(path, max_output_bytes=85)
    var enum_only: List[String] = ["enum"]
    var selected = load_table(path, enum_only^, max_output_bytes=39)
    assert_equal(selected.column(0).enumeration().value(0), "é")


def test_unused_enum_labels_are_not_serialized_as_categories() raises:
    var labels = StringBuilder()
    labels.append("unused")
    labels.append("used")
    var indices = empty[DType.uint32]([2])
    indices.unsafe_ptr()[unsafe_offset=0] = 1
    indices.unsafe_ptr()[unsafe_offset=1] = 1
    var enumeration = EnumColumn(
        labels^.freeze(), NumericColumn[DType.uint32](indices^, [], "", 0)
    )
    var table = Table(
        Schema(
            [
                SchemaNode("root", SchemaNode.GROUP, -1),
                SchemaNode("text", SchemaNode.ENUM, 0),
            ]
        ),
        [Column("text", enumeration^)],
        2,
    )
    var path = String("build/enums/unused-label.parquet")
    if exists(path):
        remove(path)
    save_table(path, table)
    var loaded = load_table(path)
    assert_equal(loaded.column(0).enumeration().value(0), "used")
    assert_equal(loaded.column(0).enumeration().value(1), "used")
    assert_equal(len(loaded.column(0).enumeration().labels()), 1)


def main() raises:
    var args = argv()
    if len(args) > 1:
        var table = load_table(args[1])
        if (
            table.num_columns() != 1
            or table.column(0).kind() != SchemaNode.ENUM
        ):
            raise Error("expected one ENUM column")
        print("rows", table.num_rows(), "kind", table.column(0).kind())
        for row in range(table.num_rows()):
            if not table.column(0).enumeration().is_valid(row):
                print("null")
            else:
                var value = table.column(0).enumeration().value(row)
                var line = String("bytes")
                for byte in value.as_bytes():
                    line += " " + String(Int(byte))
                print(line)
    else:
        TestSuite.discover_tests[__functions_in_module()]().run()
