from std.testing import TestSuite, assert_equal, assert_false, assert_raises
from numojo.routines.creation import empty
from pyroquet.binary_column import BinaryColumn
from pyroquet.string_column import StringColumn, StringBuilder
from pyroquet.numeric_column import NumericColumn
from pyroquet.enum_column import (
    EnumColumn,
    EnumBuilder,
    _enum_overhead,
    _enum_cardinality,
)


def indices(var values: List[UInt32]) raises -> NumericColumn[DType.uint32]:
    var array = empty[DType.uint32]([len(values)])
    for i in range(len(values)):
        array.unsafe_ptr()[unsafe_offset=i] = values[i]
    return NumericColumn[DType.uint32](array^, List[UInt8](), "", 0)


def test_interning_values_and_ownership() raises:
    var builder = EnumBuilder(7)
    builder.append("é\x00🦜")
    builder.append_null()
    builder.append("")
    builder.append("é\x00🦜")
    builder.append("é")
    builder.append("é")
    builder.append("")
    var column = builder^.freeze()
    var address = Int(column.indices().values().unsafe_ptr())
    var moved = column^
    assert_equal(address, Int(moved.indices().values().unsafe_ptr()))
    assert_equal(len(moved), 7)
    assert_equal(moved.null_count(), 1)
    assert_equal(len(moved.labels()), 4)
    assert_equal(moved.value(0), "é\x00🦜")
    assert_false(moved.is_valid(1))
    assert_equal(moved.value(2), "")
    assert_equal(moved.value(3), moved.value(0))
    assert_equal(moved.indices().value(3).value(), UInt32(0))
    assert_equal(moved.indices().value(6).value(), UInt32(1))
    assert_equal(moved.value(4), "é")
    assert_equal(moved.value(5), "é")
    assert_equal(moved.dictionary_byte_size(), 52)
    assert_equal(moved.storage_byte_size(), 81)
    with assert_raises():
        _ = moved.value(1)
    with assert_raises():
        _ = moved.value(-1)
    with assert_raises():
        _ = moved.is_valid(7)


def test_constructor_invariants() raises:
    with assert_raises():
        _ = EnumColumn(
            StringColumn(BinaryColumn([0, 1, 2], [65, 65])), indices([0])
        )
    with assert_raises():
        _ = EnumColumn(
            StringColumn(BinaryColumn([0, 0], List[UInt8](), [0])), indices([0])
        )
    with assert_raises():
        _ = EnumColumn(StringColumn(BinaryColumn([0, 1], [65])), indices([1]))
    with assert_raises():
        _ = EnumColumn(
            StringColumn(BinaryColumn([0], List[UInt8]())),
            indices([UInt32.MAX]),
        )
    var labels = StringBuilder()
    labels.append("unused")
    labels.append("used")
    var column = EnumColumn(labels^.freeze(), indices([1]))
    assert_equal(column.value(0), "used")
    assert_equal(len(column.labels()), 2)
    assert_equal(column.dictionary_byte_size(), 35)
    assert_equal(column.storage_byte_size(), 39)


def test_empty_nulls_and_exact_budgets() raises:
    var builder = EnumBuilder(0, max_output_bytes=8)
    var empty_column = builder^.freeze()
    assert_equal(len(empty_column), 0)
    assert_equal(empty_column.storage_byte_size(), 8)
    var nulls = EnumBuilder(19, max_output_bytes=87, max_labels=0)
    for _ in range(19):
        nulls.append_null()
    var null_column = nulls^.freeze()
    assert_equal(null_column.null_count(), 19)
    assert_equal(len(null_column.labels()), 0)
    assert_equal(null_column.storage_byte_size(), 87)
    var exact = EnumBuilder(3, max_output_bytes=31, max_labels=1)
    exact.append("é")
    exact.append("é")
    with assert_raises():
        exact.append("x")
    exact.append_null()
    with assert_raises():
        exact.append_null()
    var column = exact^.freeze()
    assert_equal(column.storage_byte_size(), 31)
    var bounded = EnumBuilder(1, max_output_bytes=21)
    with assert_raises():
        bounded.append("x")
    bounded.append("")
    assert_equal(bounded^.freeze().value(0), "")
    with assert_raises():
        var incomplete = EnumBuilder(1)
        _ = incomplete^.freeze()
    with assert_raises():
        _ = EnumBuilder(-1)
    with assert_raises():
        _ = EnumBuilder(0, max_output_bytes=7)
    with assert_raises():
        _ = EnumBuilder(0, max_output_bytes=-1)


def test_overflow_and_cardinality_without_allocating() raises:
    _enum_cardinality(4294967296)
    _enum_cardinality(0, 0)
    with assert_raises():
        _enum_cardinality(4294967297)
    with assert_raises():
        _enum_cardinality(-1)
    with assert_raises():
        _enum_cardinality(0, -1)
    with assert_raises():
        _enum_cardinality(0, 4294967297)
    with assert_raises():
        _ = _enum_overhead(Int.MAX, Int.MAX)
    with assert_raises():
        _ = _enum_overhead((Int.MAX - 8) // 4, Int.MAX)
    assert_equal(_enum_overhead(8, 41), 41)


def test_malformed_utf8_does_not_append() raises:
    var builder = EnumBuilder(1)
    var bad: List[UInt8] = [194]
    with assert_raises():
        builder.append_bytes(Span(bad))
    bad = [128]
    with assert_raises():
        builder.append_bytes(Span(bad))
    bad = [237, 160, 128]
    with assert_raises():
        builder.append_bytes(Span(bad))
    assert_equal(len(builder), 0)
    builder.append("valid")
    assert_equal(builder^.freeze().value(0), "valid")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
