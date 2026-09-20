from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_false,
    assert_true,
)
from pyroquet.boolean_column import BooleanColumn


def test_boolean_lengths_and_nulls() raises:
    for count in range(18):
        var values = List[UInt8]()
        var validity = List[UInt8]()
        for _ in range(count // 8 + Int(count % 8 != 0)):
            values.append(0)
            validity.append(0)
        for i in range(count):
            if i % 2 == 0:
                values[i // 8] |= UInt8(1) << UInt8(i % 8)
            if i % 3 != 0:
                validity[i // 8] |= UInt8(1) << UInt8(i % 8)
        var column = BooleanColumn(count, values^, validity^)
        assert_equal(len(column), count)
        assert_equal(column.null_count(), (count + 2) // 3)
        for i in range(count):
            var value = column.value(i)
            assert_equal(Bool(value), i % 3 != 0)
            if value:
                assert_equal(value.value(), i % 2 == 0)


def test_boolean_rejections() raises:
    with assert_raises():
        _ = BooleanColumn(-1, [])
    with assert_raises():
        _ = BooleanColumn(9, [1])
    with assert_raises():
        _ = BooleanColumn(1, [2])
    with assert_raises():
        _ = BooleanColumn(1, [0], [2])
    with assert_raises():
        _ = BooleanColumn(1, [0], [0, 0])
    var column = BooleanColumn(1, [1])
    assert_true(column.value(0).value())
    with assert_raises():
        _ = column.value(-1)
    with assert_raises():
        _ = column.value(1)


def retained_boolean() raises -> BooleanColumn:
    var original = BooleanColumn(
        9, [UInt8(255), UInt8(1)], [UInt8(254), UInt8(1)]
    )
    var shared = original.copy()
    assert_equal(
        Int(original._values[].unsafe_ptr()), Int(shared._values[].unsafe_ptr())
    )
    assert_equal(shared._values[].size, 2)
    assert_equal(shared._values[].unsafe_ptr()[unsafe_offset=0], UInt8(254))
    return shared^


def test_shared_numojo_packed_storage() raises:
    var retained = retained_boolean()
    assert_equal(len(retained), 9)
    assert_equal(retained.null_count(), 1)
    assert_false(Bool(retained.value(0)))
    assert_true(retained.value(8).value())
    var empty = BooleanColumn(0, [])
    var shared_empty = empty.copy()
    assert_equal(shared_empty._values[].size, 0)
    assert_equal(len(shared_empty), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
