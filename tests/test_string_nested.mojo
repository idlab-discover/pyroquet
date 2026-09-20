"""STRING nested shape, metadata, projection and exact retained-budget gates."""
from std.testing import assert_equal, assert_false, assert_raises, TestSuite
from std.os import remove
from std.pathlib import Path
from pyroquet.schema import Schema, SchemaNode
from pyroquet.table import Column
from pyroquet.binary_column import BinaryColumn
from pyroquet.string_column import StringColumn
from pyroquet.nested_table import NestedTable, NestedStructure
from pyroquet.nested_io import load_nested_table, _leaf_overhead
from pyroquet.nested_write import save_nested_table
from pyroquet.table_write import TableWriteOptions, ColumnWriteOptions
from pyroquet.format import inspect_metadata


def string_nested_table() raises -> NestedTable:
    var schema = Schema(
        [
            SchemaNode("schema", SchemaNode.GROUP, -1),
            SchemaNode("s", SchemaNode.GROUP, 0, True),
            SchemaNode("text", SchemaNode.STRING, 1, True),
            SchemaNode("labels", SchemaNode.LIST, 1, True),
            SchemaNode("element", SchemaNode.STRING, 3, True),
        ]
    )
    var bytes: List[UInt8] = [195, 169, 97, 0, 98, 240, 159, 152, 128]
    var text = StringColumn(
        BinaryColumn([0, 0, 0, 2, 5, 9], bytes.copy(), [UInt8(30)])
    )
    var labels = StringColumn(
        BinaryColumn([0, 0, 0, 2, 5, 9], bytes^, [UInt8(29)])
    )
    return NestedTable(
        schema^,
        [Column("text", text^), Column("element", labels^)],
        [
            NestedStructure(5, [UInt8(30)]),
            NestedStructure(5, [UInt8(26)], [0, 0, 0, 0, 3, 5]),
        ],
        5,
    )


def test_nested_string_roundtrip_and_projection() raises:
    var table = string_nested_table()
    for version in range(1, 3):
        for codec in [0, 1, 2, 6]:
            var path = (
                "build/string-nested-v"
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
                assert_equal(metadata.schema[index].logical_type, 1)
                assert_equal(metadata.schema[index].converted_type, 0)
            var loaded = load_nested_table(path)
            assert_equal(loaded.num_rows(), 5)
            assert_equal(loaded.num_leaves(), 2)
            assert_equal(loaded.schema().node(2).kind(), SchemaNode.STRING)
            assert_equal(loaded.schema().node(4).kind(), SchemaNode.STRING)
            for leaf in range(2):
                assert_equal(loaded.leaf(leaf).kind(), SchemaNode.STRING)
                for row in range(5):
                    var valid = table.leaf(leaf).string().is_valid(row)
                    assert_equal(
                        loaded.leaf(leaf).string().is_valid(row), valid
                    )
                    if valid:
                        assert_equal(
                            loaded.leaf(leaf).string().value(row),
                            table.leaf(leaf).string().value(row),
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
                    SchemaNode.STRING, loaded.leaf(leaf).size(), Int.MAX
                )
                budget += loaded.leaf(leaf).string().binary().byte_size()
            _ = load_nested_table(path, max_output_bytes=budget)
            with assert_raises():
                _ = load_nested_table(path, max_output_bytes=budget - 1)
            var projection: List[List[String]] = [["s", "labels"]]
            var selected = load_nested_table(path, projection^)
            assert_equal(selected.num_leaves(), 1)
            assert_equal(selected.leaf(0).string().value(2), "é")
            assert_equal(selected.leaf(0).string().value(3), "a\0b")
            assert_equal(selected.leaf(0).string().value(4), "😀")
            assert_false(selected.leaf(0).string().is_valid(1))


def test_external_nested_dictionary_strings() raises:
    var expected = string_nested_table()
    for version in range(1, 3):
        for codec in [0, 1, 2, 6]:
            var path = (
                "build/strings/arrow-nested-v"
                + String(version)
                + "-c"
                + String(codec)
                + ".parquet"
            )
            var loaded = load_nested_table(path)
            assert_equal(loaded.num_rows(), 5)
            assert_equal(loaded.num_leaves(), 2)
            for leaf in range(2):
                assert_equal(loaded.leaf(leaf).kind(), SchemaNode.STRING)
                assert_equal(
                    loaded.leaf(leaf).size(), expected.leaf(leaf).size()
                )
                for row in range(5):
                    var valid = expected.leaf(leaf).string().is_valid(row)
                    assert_equal(
                        loaded.leaf(leaf).string().is_valid(row), valid
                    )
                    if valid:
                        assert_equal(
                            loaded.leaf(leaf).string().value(row),
                            expected.leaf(leaf).string().value(row),
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
        "",
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
    ]
    for version in range(1, 3):
        for codec in [0, 1, 2, 6]:
            var suffix = "v" + String(version) + "-c" + String(codec)
            for annotation in [
                String("both"),
                String("modern"),
                String("legacy"),
            ]:
                var table = load_nested_table(
                    "build/strings/wire-"
                    + suffix
                    + "-"
                    + annotation
                    + ".parquet"
                )
                assert_equal(table.leaf(0).kind(), SchemaNode.STRING)
                assert_equal(table.num_rows(), 10)
                for row in range(10):
                    var valid = row != 1 and row != 5 and row != 8
                    assert_equal(table.leaf(0).string().is_valid(row), valid)
                    if valid:
                        assert_equal(
                            table.leaf(0).string().value(row), expected[row]
                        )
            for fixture in malformed:
                with assert_raises():
                    _ = load_nested_table(
                        "build/strings/invalid-"
                        + suffix
                        + "-"
                        + fixture
                        + ".parquet"
                    )
    for physical in [0, 1, 2]:
        with assert_raises():
            _ = load_nested_table(
                "build/strings/invalid-physical-"
                + String(physical)
                + ".parquet"
            )
    for encoding in [
        String("DELTA_LENGTH_BYTE_ARRAY"),
        String("DELTA_BYTE_ARRAY"),
    ]:
        with assert_raises():
            _ = load_nested_table(
                "build/strings/unsupported-" + encoding + ".parquet"
            )


def test_empty_and_all_null_nested_strings() raises:
    for rows in [0, 4]:
        var schema = Schema(
            [
                SchemaNode("schema", SchemaNode.GROUP, -1),
                SchemaNode("s", SchemaNode.GROUP, 0),
                SchemaNode("text", SchemaNode.STRING, 1, True),
            ]
        )
        var offsets = List[Int](length=rows + 1, fill=0)
        var validity = List[UInt8](length=Int(rows != 0), fill=0)
        var column = StringColumn(BinaryColumn(offsets^, [], validity^))
        var table = NestedTable(
            schema^, [Column("text", column^)], [NestedStructure(rows)], rows
        )
        var path = "build/string-nested-empty-" + String(rows) + ".parquet"
        if Path(path).exists():
            remove(path)
        save_nested_table(path, table)
        var loaded = load_nested_table(path)
        assert_equal(loaded.num_rows(), rows)
        assert_equal(loaded.leaf(0).size(), rows)
        for row in range(rows):
            assert_false(loaded.leaf(0).string().is_valid(row))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
