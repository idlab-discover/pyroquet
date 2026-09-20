"""Shared handles preserve schema/nulls and ENUM dictionary invariants."""
from std.testing import assert_equal, assert_false, assert_raises, TestSuite
from numojo.routines.creation import empty
from numojo.core.ndarray import NDArray
from pyroquet import Schema, SchemaNode, Column, Table
from pyroquet.numeric_column import NumericColumn
from pyroquet.string_column import StringBuilder
from pyroquet.enum_column import EnumColumn, EnumBuilder
from pyroquet.numojo_write import save_numeric
from pyroquet.numojo_io import load_numeric
from pyroquet.table_write import save_table
from pyroquet.table_io import load_table
from pyroquet.nested_write import save_nested_table
from pyroquet.nested_io import load_nested_table
from test_nested_table import make_table
from std.os import remove
from std.pathlib import Path


def fresh() raises -> NumericColumn[DType.int32]:
    var values = empty[DType.int32]([3])
    values.fill(1)
    return NumericColumn(values^, [UInt8(5)], "x", 1)


def remove_previous(path: String) raises:
    if Path(path).exists():
        remove(path)


def test_shared_payload_and_local_handle() raises:
    var column = fresh()
    var a = column.values_mut()
    var b = column.values().view_with_layout(
        column.values().shape, column.values().strides, 0
    )
    a.fill(7)
    b.store(2, 9)
    assert_equal(column.value(0).value(), 7)
    assert_equal(a.load(2), 9)
    assert_false(Bool(column.value(1)))
    # Layout and replacement belong to the returned handle, not the column.
    a.shape[0] = 1
    a.size = 1
    assert_equal(column.size(), 3)
    assert_equal(column.values().shape[0], 3)
    a = empty[DType.int32]([20])
    a.fill(99)
    assert_equal(column.value(0).value(), 7)
    var path = "build/mutation-numeric.parquet"
    remove_previous(path)
    save_numeric(path, column)
    var loaded = load_numeric[DType.int32](path, "x")
    assert_equal(loaded.value(0).value(), 7)
    assert_equal(loaded.value(2).value(), 9)
    assert_false(Bool(loaded.value(1)))
    assert_equal(loaded.validity()[0], UInt8(5))


def escaped_handle() raises -> NDArray[DType.int32]:
    var column = fresh()
    return column.values_mut()


def test_shared_handle_retains_allocation() raises:
    var values = escaped_handle()
    values.fill(17)
    assert_equal(values.load(2), 17)


def test_table_mutation_roundtrip() raises:
    var table = Table(
        Schema(
            [
                SchemaNode("schema", SchemaNode.GROUP, -1),
                SchemaNode("x", SchemaNode.INT32, 0, True),
            ]
        ),
        [Column(fresh())],
        3,
    )
    var a = table.values_mut[DType.int32](0)
    a.fill(13)
    var b = table.column(0).values_mut[DType.int32]()
    b.store(2, 29)
    assert_equal(table.column(0).numeric[DType.int32]().value(2).value(), 29)
    var path = "build/mutation-table.parquet"
    remove_previous(path)
    save_table(path, table)
    var loaded = load_table(path)
    assert_equal(loaded.num_rows(), 3)
    assert_equal(loaded.column(0).numeric[DType.int32]().value(0).value(), 13)
    assert_equal(loaded.column(0).numeric[DType.int32]().value(2).value(), 29)
    assert_false(Bool(loaded.column(0).numeric[DType.int32]().value(1)))


def test_nested_mutation_roundtrip() raises:
    var table = make_table()
    var a = table.values_mut[DType.int32](0)
    a.fill(31)
    var b = table.leaf(0).values_mut[DType.int32]()
    b.store(0, 47)
    var path = "build/mutation-nested.parquet"
    remove_previous(path)
    save_nested_table(path, table)
    var loaded = load_nested_table(path)
    assert_equal(loaded.num_rows(), 4)
    assert_equal(loaded.leaf(0).numeric[DType.int32]().value(0).value(), 47)
    assert_false(Bool(loaded.leaf(0).numeric[DType.int32]().value(1)))
    assert_false(loaded.structure(1).is_valid(0))
    assert_false(loaded.structure(2).is_valid(1))
    assert_equal(loaded.structure(2).offset(2), loaded.structure(2).offset(3))


def test_enum_snapshot_and_checked_update() raises:
    var labels = StringBuilder()
    labels.append("a")
    labels.append("b")
    var values = empty[DType.uint32]([3])
    values.fill(0)
    var indices = NumericColumn(values^, [UInt8(5)], "x", 1)
    var retained = indices.values_mut()
    var column = EnumColumn(labels^.freeze(), indices^)
    retained.fill(999)
    assert_equal(column.value(0), "a")
    column.set_index(2, 1)
    assert_equal(column.value(2), "b")
    with assert_raises():
        column.set_index(0, 2)
    with assert_raises():
        column.set_index(1, 1)
    with assert_raises():
        column.set_index(-1, 1)
    with assert_raises():
        column.set_index(3, 1)
    assert_equal(column.value(0), "a")
    assert_equal(column.value(2), "b")
    assert_false(column.is_valid(1))
    assert_equal(column.indices().validity()[0], UInt8(5))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
