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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
