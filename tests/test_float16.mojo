"""FLOAT16 bit-preserving flat/nested PLAIN and dictionary release checks."""
from test_nullable_dictionary import _typed
from std.memory import bitcast
from std.os import remove
from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_raises, TestSuite
from numojo.routines.creation import empty
from pyroquet.numeric_column import NumericColumn
from pyroquet.numojo_io import (
    load_numeric,
    _matches_numeric,
    _plain_value,
    _decode_plain_values,
)
from pyroquet.numojo_write import save_numeric, NumericWriteOptions
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)
from pyroquet.nested_io import load_nested_table
from pyroquet.nested_write import save_nested_table
from pyroquet.schema import SchemaNode
from pyroquet.format.metadata import SchemaElement
from pyroquet.format import inspect_metadata


def bits(index: Int) -> UInt16:
    var patterns: List[UInt16] = [
        0,
        0x8000,
        1,
        0x3FF,
        0x400,
        0x3C00,
        0x7BFF,
        0x7C00,
        0xFC00,
        0x7E01,
        0x7C01,
        0xFE55,
        0x3555,
    ]
    return patterns[index]


def check(column: NumericColumn[DType.float16], mode: String) raises:
    var rows = 65536 if mode == "exhaustive" else (0 if mode == "empty" else 13)
    assert_equal(column.size(), rows)
    var nulls = 0
    for i in range(rows):
        var valid = mode != "allnull" and (mode != "nullable" or i % 3 != 0)
        var value = column.value(i)
        assert_equal(Bool(value), valid)
        if valid:
            assert_equal(
                bitcast[DType.uint16](value.value()),
                UInt16(i) if mode == "exhaustive" else bits(i),
            )
        else:
            nulls += 1
    assert_equal(column.null_count(), nulls)


def fresh(path: String) raises:
    if Path(path).exists():
        remove(path)


def test_float16_read_write_matrix() raises:
    var codecs: List[Int] = [0, 1, 2, 6]
    var modes: List[String] = [
        "required",
        "nullable",
        "empty",
        "allnull",
        "exhaustive",
    ]
    for version in range(1, 3):
        for codec in codecs:
            for dictionary in range(2):
                for mode in modes:
                    var suffix = (
                        "v"
                        + String(version)
                        + "-c"
                        + String(codec)
                        + "-d"
                        + String(dictionary)
                        + "-"
                        + mode
                    )
                    var source = "build/float16/in-" + suffix + ".parquet"
                    var loaded = load_numeric[DType.float16](source, "half")
                    check(loaded, mode)
                    var table = load_table(source)
                    assert_equal(table.column(0).dtype(), DType.float16)
                    assert_equal(
                        table.schema().node(1).kind(), SchemaNode.FLOAT16
                    )
                    check(table.column(0).numeric[DType.float16](), mode)
                    var target = "build/float16/out-" + suffix + ".parquet"
                    fresh(target)
                    save_numeric[DType.float16](
                        target,
                        loaded,
                        NumericWriteOptions(
                            nullable=mode != "required",
                            codec=codec,
                            page_version=version,
                            page_rows=257,
                            row_group_rows=16387,
                        ),
                    )
                    var result = load_numeric[DType.float16](target, "half")
                    check(result, mode)
                    var metadata = inspect_metadata(target)
                    assert_equal(metadata.schema[1].physical_type, 7)
                    assert_equal(metadata.schema[1].type_length, 2)
                    assert_equal(metadata.schema[1].logical_type, 15)
                    assert_equal(metadata.schema[1].converted_type, -1)
                    var table_target = (
                        "build/float16/table-" + suffix + ".parquet"
                    )
                    fresh(table_target)
                    save_table(
                        table_target,
                        table,
                        TableWriteOptions(row_group_rows=16387),
                        [
                            ColumnWriteOptions(
                                codec=codec, page_version=version, page_rows=257
                            )
                        ],
                    )
                    var reloaded = load_table(table_target)
                    check(reloaded.column(0).numeric[DType.float16](), mode)


def test_float16_nested() raises:
    var codecs: List[Int] = [0, 1, 2, 6]
    for version in range(1, 3):
        for codec in codecs:
            var suffix = (
                "v" + String(version) + "-c" + String(codec) + ".parquet"
            )
            var table = load_nested_table("build/float16/nested-" + suffix)
            check(table.leaf(0).numeric[DType.float16](), "nullable")
            check(table.leaf(1).numeric[DType.float16](), "nullable")
            var target = "build/float16/nested-out-" + suffix
            fresh(target)
            save_nested_table(
                target,
                table,
                TableWriteOptions(row_group_rows=5),
                [
                    ColumnWriteOptions(
                        codec=codec, page_version=version, page_rows=2
                    ),
                    ColumnWriteOptions(
                        codec=codec, page_version=version, page_rows=2
                    ),
                ],
            )
            var result = load_nested_table(target)
            assert_equal(result.num_rows(), 13)
            check(result.leaf(0).numeric[DType.float16](), "nullable")
            check(result.leaf(1).numeric[DType.float16](), "nullable")


def test_float16_malformed_and_budget() raises:
    var node = SchemaElement()
    node.physical_type = 7
    node.logical_type = 15
    node.type_length = 2
    assert_equal(_matches_numeric[DType.float16](node), True)
    node.type_length = 4
    assert_false(_matches_numeric[DType.float16](node))
    node.type_length = 2
    node.converted_type = 0
    assert_false(_matches_numeric[DType.float16](node))
    node.converted_type = -1
    node.physical_type = 1
    assert_false(_matches_numeric[DType.float16](node))
    with assert_raises():
        _ = _plain_value[DType.float16]([UInt8(0)], 0)
    var values = empty[DType.float16]([2])
    with assert_raises():
        _decode_plain_values[DType.float16](
            [UInt8(0), UInt8(0), UInt8(0)], 0, values.unsafe_ptr(), 2
        )
    with assert_raises():
        _ = load_numeric[DType.float16](
            "build/float16/in-v1-c0-d0-exhaustive.parquet",
            "half",
            max_output_bytes=131071,
        )


def test_float16_wire_rejection_and_dictionary_bounds() raises:
    var control = load_numeric[DType.float16](
        "build/float16/wire-control.parquet", "half"
    )
    assert_equal(
        bitcast[DType.uint16](control.value(1).value()), UInt16(0x8000)
    )
    assert_equal(
        bitcast[DType.uint16](control.value(2).value()), UInt16(0x7E01)
    )
    var invalid: List[String] = [
        "width1",
        "width4",
        "missing-width",
        "legacy",
        "physical",
        "truncated",
        "delta",
    ]
    for fixture in invalid:
        var path = "build/float16/wire-" + fixture + ".parquet"
        with assert_raises():
            _ = load_numeric[DType.float16](path, "half")
        with assert_raises():
            _ = load_table(path)
        with assert_raises():
            _ = load_nested_table(path)
    _typed[DType.float16]()


def test_float16_shared_mutation_and_nulls() raises:
    var table = load_table("build/float16/in-v1-c0-d0-nullable.parquet")
    var values = table.values_mut[DType.float16](0)
    values.fill(7)
    values.store(1, bitcast[DType.float16](UInt16(0x8000)))
    assert_false(Bool(table.column(0).numeric[DType.float16]().value(0)))
    assert_equal(
        bitcast[DType.uint16](
            table.column(0).numeric[DType.float16]().value(1).value()
        ),
        UInt16(0x8000),
    )
    var target = "build/float16/mutation.parquet"
    fresh(target)
    save_table(target, table)
    var result = load_table(target)
    for i in range(13):
        var value = result.column(0).numeric[DType.float16]().value(i)
        assert_equal(Bool(value), i % 3 != 0)
        if value:
            assert_equal(
                bitcast[DType.uint16](value.value()),
                UInt16(0x8000) if i == 1 else bitcast[DType.uint16](Float16(7)),
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
