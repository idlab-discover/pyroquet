from std.testing import TestSuite, assert_equal, assert_raises
from pyroquet.binary_column import BinaryColumn
from pyroquet.boolean_column import BooleanColumn
from pyroquet.format.binary_values import (
    decode_plain_binary,
    encode_plain_binary,
)
from pyroquet.format.boolean_values import (
    decode_boolean_values,
    encode_plain_boolean,
)


def test_binary_exact_wire() raises:
    var column = BinaryColumn([0, 0, 0, 3], [0, 255, 128], [5])
    var wire = encode_plain_binary(column, 0, 3, 11)
    var expected: List[UInt8] = [0, 0, 0, 0, 3, 0, 0, 0, 0, 255, 128]
    assert_equal(len(wire), len(expected))
    for i in range(len(wire)):
        assert_equal(wire[i], expected[i])
    var decoded = decode_plain_binary(wire, 2, max_bytes=3)
    assert_equal(len(decoded.value(0)), 0)
    assert_equal(decoded.value(1)[1], UInt8(255))
    with assert_raises():
        _ = encode_plain_binary(column, 0, 3, 10)
    with assert_raises():
        _ = decode_plain_binary(wire, 2, max_bytes=2)


def test_fixed_binary_wire() raises:
    var column = BinaryColumn(
        [0, 2, 2, 4], [0, 255, 128, 1], [5], fixed_width=2
    )
    var wire = encode_plain_binary(column, 0, 3, 4)
    assert_equal(len(wire), 4)
    var decoded = decode_plain_binary(wire, 2, fixed_width=2)
    assert_equal(decoded.value(1)[0], UInt8(128))
    with assert_raises():
        _ = decode_plain_binary(wire, Int.MAX, fixed_width=2)
    with assert_raises():
        _ = decode_plain_binary(wire, 1, fixed_width=3)


def test_binary_malformed() raises:
    with assert_raises():
        _ = decode_plain_binary([1, 0, 0], 1)
    with assert_raises():
        _ = decode_plain_binary([2, 0, 0, 0, 42], 1)
    with assert_raises():
        _ = decode_plain_binary([255, 255, 255, 255], 1)
    with assert_raises():
        _ = decode_plain_binary([0], 0)
    with assert_raises():
        _ = decode_plain_binary([], -1)


def test_boolean_plain_and_null_compaction() raises:
    var column = BooleanColumn(9, [85, 1], [253, 1])
    var wire = encode_plain_boolean(column, 0, 9)
    assert_equal(len(wire), 1)
    assert_equal(wire[0], UInt8(171))
    var decoded = decode_boolean_values(wire, 8)
    for i in range(8):
        var source_row = i if i == 0 else i + 1
        assert_equal(decoded.value(i).value(), column.value(source_row).value())
    var subpage = encode_plain_boolean(column, 3, 6)
    assert_equal(subpage[0], UInt8(42))
    with assert_raises():
        _ = decode_boolean_values(wire, 9)
    for count in range(10):
        var bytes = List[UInt8]()
        for _ in range(count // 8 + Int(count % 8 != 0)):
            bytes.append(255)
        var all_true = decode_boolean_values(bytes, count)
        for i in range(count):
            assert_equal(all_true.value(i).value(), True)


def test_boolean_rle_prefix_and_packing() raises:
    var column = decode_boolean_values([2, 0, 0, 0, 18, 1], 9, encoding=3)
    assert_equal(len(column), 9)
    for i in range(9):
        assert_equal(column.value(i).value(), True)
    var packed = decode_boolean_values([2, 0, 0, 0, 3, 85], 7, encoding=3)
    for i in range(7):
        assert_equal(packed.value(i).value(), i % 2 == 0)
    with assert_raises():
        _ = decode_boolean_values([18, 1], 9, encoding=3)
    with assert_raises():
        _ = decode_boolean_values([3, 0, 0, 0, 18, 1], 9, encoding=3)
    with assert_raises():
        _ = decode_boolean_values([1, 0, 0, 0, 18], 9, encoding=3)
    with assert_raises():
        _ = decode_boolean_values([], 0, encoding=8)


def test_boolean_long_run_and_empty_rle() raises:
    var column = decode_boolean_values([4, 0, 0, 0, 130, 128, 1, 1], 8193, encoding=3)
    for i in range(8193):
        assert_equal(column.value(i).value(), True)
    var empty = decode_boolean_values([0, 0, 0, 0], 0, encoding=3)
    assert_equal(len(empty), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
