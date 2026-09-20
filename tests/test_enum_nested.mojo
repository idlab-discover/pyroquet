"""ENUM nested shape, metadata, projection and exact retained-budget gates."""
from std.testing import assert_equal, assert_false, assert_raises, TestSuite
from std.os import remove
from std.pathlib import Path
from pyroquet.schema import Schema, SchemaNode
from pyroquet.table import Column
from pyroquet.binary_column import BinaryColumn
from pyroquet.enum_column import EnumBuilder
from pyroquet.nested_table import NestedTable, NestedStructure
from pyroquet.nested_io import load_nested_table, _leaf_overhead
from pyroquet.nested_write import save_nested_table
from pyroquet.table_write import TableWriteOptions, ColumnWriteOptions
from pyroquet.format import inspect_metadata


def enum_nested_table() raises -> NestedTable:
    var schema = Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("s", SchemaNode.GROUP, 0, True),
            SchemaNode("text", SchemaNode.ENUM, 1, True),
            SchemaNode("labels", SchemaNode.LIST, 1, True),
            SchemaNode("element", SchemaNode.ENUM, 3, True),
        ]
    )
    var bytes: List[UInt8] = [195, 169, 97, 0, 98, 240, 159, 152, 128]
    var text_builder = EnumBuilder(5)
    var labels_builder = EnumBuilder(5)
    var text_bytes = BinaryColumn([0, 0, 0, 2, 5, 9], bytes.copy(), [UInt8(30)])
    var label_bytes = BinaryColumn([0, 0, 0, 2, 5, 9], bytes^, [UInt8(29)])
    for row in range(5):
        if text_bytes.is_valid(row):
            text_builder.append_bytes(text_bytes.value(row))
        else:
            text_builder.append_null()
        if label_bytes.is_valid(row):
            labels_builder.append_bytes(label_bytes.value(row))
        else:
            labels_builder.append_null()
    var text = text_builder^.freeze()
    var labels = labels_builder^.freeze()
    return NestedTable(
        schema^,
        [Column("text", text^), Column("element", labels^)],
        [
            NestedStructure(5, [UInt8(30)]),
            NestedStructure(5, [UInt8(26)], [0, 0, 0, 0, 3, 5]),
        ],
        5,
    )


def test_nested_enum_roundtrip_and_projection() raises:
    var table = enum_nested_table()
    for version in range(1, 3):
        for codec in [0, 1, 2, 6]:
            var path = (
                "build/enum-nested-v"
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
                        page_rows=1, page_version=version, codec=codec
                    ),
                    ColumnWriteOptions(
                        page_rows=2, page_version=version, codec=codec
                    ),
                ],
            )
            var metadata = inspect_metadata(path)
            for index in [2, 5]:
                assert_equal(metadata.schema[index].physical_type, 6)
                assert_equal(metadata.schema[index].logical_type, 4)
                assert_equal(metadata.schema[index].converted_type, 4)
            var loaded = load_nested_table(path)
            assert_equal(loaded.num_rows(), 5)
            assert_equal(loaded.num_leaves(), 2)
            assert_equal(loaded.schema().node(2).kind(), SchemaNode.ENUM)
            assert_equal(loaded.schema().node(4).kind(), SchemaNode.ENUM)
            for leaf in range(2):
                assert_equal(loaded.leaf(leaf).kind(), SchemaNode.ENUM)
                for row in range(5):
                    var valid = table.leaf(leaf).enumeration().is_valid(row)
                    assert_equal(
                        loaded.leaf(leaf).enumeration().is_valid(row), valid
                    )
                    if valid:
                        assert_equal(
                            loaded.leaf(leaf).enumeration().value(row),
                            table.leaf(leaf).enumeration().value(row),
                        )
            for row in range(5):
                assert_equal(
                    loaded.structure(1).is_valid(row),
                    table.structure(1).is_valid(row),
                )
                assert_equal(
                    loaded.structure(3).is_valid(row),
                    table.structure(3).is_valid(row),
                )
            for row in range(6):
                assert_equal(
                    loaded.structure(3).offset(row),
                    table.structure(3).offset(row),
                )
            var budget = (
                loaded.structure(1).retained_bytes()
                + loaded.structure(3).retained_bytes()
            )
            for leaf in range(2):
                budget += _leaf_overhead(
                    SchemaNode.ENUM, loaded.leaf(leaf).size(), Int.MAX
                )
                budget += (
                    loaded.leaf(leaf).enumeration().dictionary_byte_size() - 8
                )
            _ = load_nested_table(path, max_output_bytes=budget)
            with assert_raises():
                _ = load_nested_table(path, max_output_bytes=budget - 1)
            var projection: List[List[String]] = [["s", "labels"]]
            var selected = load_nested_table(path, projection^)
            assert_equal(selected.num_leaves(), 1)
            assert_equal(selected.leaf(0).enumeration().value(2), "é")
            assert_equal(selected.leaf(0).enumeration().value(3), "a\0b")
            assert_equal(selected.leaf(0).enumeration().value(4), "😀")
            assert_false(selected.leaf(0).enumeration().is_valid(1))


def test_external_nested_dictionary_enums() raises:
    var control = load_nested_table(
        "build/enums/dictionary-string-control.parquet"
    )
    assert_equal(control.leaf(0).kind(), SchemaNode.STRING)
    with assert_raises():
        _ = control.leaf(0).enumeration().value(0)
    var expected = enum_nested_table()
    for version in range(1, 3):
        for codec in [0, 1, 2, 6]:
            var path = (
                "build/enums/arrow-nested-v"
                + String(version)
                + "-c"
                + String(codec)
                + ".parquet"
            )
            var loaded = load_nested_table(path)
            assert_equal(loaded.num_rows(), 5)
            assert_equal(loaded.num_leaves(), 2)
            for leaf in range(2):
                assert_equal(loaded.leaf(leaf).kind(), SchemaNode.ENUM)
                assert_equal(
                    loaded.leaf(leaf).size(), expected.leaf(leaf).size()
                )
                for row in range(5):
                    var valid = expected.leaf(leaf).enumeration().is_valid(row)
                    assert_equal(
                        loaded.leaf(leaf).enumeration().is_valid(row), valid
                    )
                    if valid:
                        assert_equal(
                            loaded.leaf(leaf).enumeration().value(row),
                            expected.leaf(leaf).enumeration().value(row),
                        )
            for row in range(5):
                assert_equal(
                    loaded.structure(1).is_valid(row),
                    expected.structure(1).is_valid(row),
                )
                assert_equal(
                    loaded.structure(3).is_valid(row),
                    expected.structure(3).is_valid(row),
                )
            for row in range(6):
                assert_equal(
                    loaded.structure(3).offset(row),
                    expected.structure(3).offset(row),
                )


def test_nested_reader_mixed_encoding_and_malformed_text() raises:
    var expected: List[String] = [
        "中文",
        "",
        "a\0b",
        "中文",
        "a\0b",
        "",
        "",
        "😀",
        "",
        "",
    ]
    var malformed: List[String] = [
        "overlong",
        "surrogate",
        "above_unicode",
        "truncated",
        "boundary_split",
        "continuation",
        "dictionary-id",
        "unused-dictionary-utf8",
    ]
    for version in range(1, 3):
        for codec in [0, 1, 2, 6]:
            var suffix = "v" + String(version) + "-c" + String(codec)
            for annotation in [
                String("both"),
                String("modern"),
                String("legacy"),
                String("modern_wins"),
            ]:
                var table = load_nested_table(
                    "build/enums/wire-" + suffix + "-" + annotation + ".parquet"
                )
                assert_equal(table.leaf(0).kind(), SchemaNode.ENUM)
                assert_equal(table.num_rows(), 10)
                for row in range(10):
                    var valid = row != 1 and row != 5 and row != 8
                    assert_equal(
                        table.leaf(0).enumeration().is_valid(row), valid
                    )
                    if valid:
                        assert_equal(
                            table.leaf(0).enumeration().value(row),
                            expected[row],
                        )
            for fixture in malformed:
                with assert_raises():
                    _ = load_nested_table(
                        "build/enums/invalid-"
                        + suffix
                        + "-"
                        + fixture
                        + ".parquet"
                    )
    for physical in [0, 1, 2]:
        with assert_raises():
            _ = load_nested_table(
                "build/enums/invalid-physical-" + String(physical) + ".parquet"
            )
    for encoding in [
        String("DELTA_LENGTH_BYTE_ARRAY"),
        String("DELTA_BYTE_ARRAY"),
    ]:
        with assert_raises():
            _ = load_nested_table(
                "build/enums/unsupported-" + encoding + ".parquet"
            )


def test_empty_and_all_null_nested_enums() raises:
    for rows in [0, 4]:
        var schema = Schema(
            [
                SchemaNode("schema", SchemaNode.GROUP, -1),
                SchemaNode("s", SchemaNode.GROUP, 0),
                SchemaNode("text", SchemaNode.ENUM, 1, True),
            ]
        )
        var builder = EnumBuilder(rows)
        for _ in range(rows):
            builder.append_null()
        var column = builder^.freeze()
        var table = NestedTable(
            schema^, [Column("text", column^)], [NestedStructure(rows)], rows
        )
        var path = "build/enum-nested-empty-" + String(rows) + ".parquet"
        if Path(path).exists():
            remove(path)
        save_nested_table(path, table)
        var loaded = load_nested_table(path)
        assert_equal(loaded.num_rows(), rows)
        assert_equal(loaded.leaf(0).size(), rows)
        for row in range(rows):
            assert_false(loaded.leaf(0).enumeration().is_valid(row))


def test_enum_nested_parent_validity_and_compact_budget() raises:
    var builder = EnumBuilder(3)
    builder.append("repeated label")
    builder.append("repeated label")
    builder.append("repeated label")
    var schema = Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("s", SchemaNode.GROUP, 0, True),
            SchemaNode("e", SchemaNode.ENUM, 1, True),
        ]
    )
    with assert_raises():
        _ = NestedTable(
            schema.copy(),
            [Column("e", builder^.freeze())],
            [NestedStructure(3, [UInt8(3)])],
            3,
        )
    var repeated = EnumBuilder(100)
    for _ in range(100):
        repeated.append("a substantially repeated label")
    var table = NestedTable(
        schema^,
        [Column("e", repeated^.freeze())],
        [NestedStructure(100)],
        100,
    )
    var path = "build/enum-nested-repeated.parquet"
    if Path(path).exists():
        remove(path)
    save_nested_table(path, table, TableWriteOptions(row_group_rows=7))
    var budget = (
        _leaf_overhead(SchemaNode.ENUM, 100, Int.MAX)
        + table.leaf(0).enumeration().dictionary_byte_size()
        - 8
        + 13
    )
    var loaded = load_nested_table(path, max_output_bytes=budget)
    assert_equal(len(loaded.leaf(0).enumeration().labels()), 1)
    for row in range(100):
        assert_equal(
            loaded.leaf(0).enumeration().value(row),
            "a substantially repeated label",
        )
    with assert_raises():
        _ = load_nested_table(path, max_output_bytes=budget - 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
