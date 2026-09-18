from std.testing import TestSuite, assert_equal, assert_raises, assert_false
from pyroquet.binary_column import BinaryColumn
from pyroquet.string_column import StringColumn, StringBuilder


def test_values_and_shared_ownership() raises:
    var builder = StringBuilder()
    builder.append("")
    builder.append_null()
    builder.append("héllo 🦜\x00尾")
    var column = builder^.freeze()
    assert_equal(len(column), 3)
    assert_equal(column.null_count(), 1)
    assert_equal(column.byte_size(), String("héllo 🦜\x00尾").byte_length())
    assert_equal(column.value(0), "")
    assert_false(column.is_valid(1))
    assert_equal(column.value(2), "héllo 🦜\x00尾")
    with assert_raises():
        _ = column.value(1)
    with assert_raises():
        _ = column.value(-1)
    with assert_raises():
        _ = column.value(3)
    var shared = column.copy()
    assert_equal(
        Int(shared.binary().value(2).unsafe_ptr()),
        Int(column.binary().value(2).unsafe_ptr()),
    )
    var owned = column.value(2)
    assert_equal(owned, "héllo 🦜\x00尾")


def test_empty_all_null_and_budget() raises:
    var empty = StringBuilder(max_bytes=0)
    var empty_column = empty^.freeze()
    assert_equal(len(empty_column), 0)
    var builder = StringBuilder(max_bytes=2, byte_capacity=2)
    builder.append("é")
    with assert_raises():
        builder.append("x")
    builder.append_null()
    builder.append("")
    var column = builder^.freeze()
    assert_equal(len(column), 3)
    assert_equal(column.value(0), "é")
    assert_equal(column.value(2), "")
    var nulls = StringBuilder(max_bytes=0)
    for _ in range(19):
        nulls.append_null()
    var all_null = nulls^.freeze()
    assert_equal(all_null.null_count(), 19)
    assert_equal(all_null.byte_size(), 0)
    with assert_raises():
        _ = StringBuilder(max_bytes=-1)
    with assert_raises():
        _ = StringBuilder(max_bytes=1, byte_capacity=2)


def reject_utf8(var bytes: List[UInt8]) raises:
    var size = len(bytes)
    with assert_raises():
        _ = StringColumn(BinaryColumn([0, size], bytes^))


def test_invalid_utf8() raises:
    reject_utf8([128])
    reject_utf8([191])
    reject_utf8([192, 128])
    reject_utf8([193, 191])
    reject_utf8([194])
    reject_utf8([194, 65])
    reject_utf8([224, 159, 191])
    reject_utf8([237, 160, 128])
    reject_utf8([239, 191])
    reject_utf8([239, 191, 0])
    reject_utf8([240, 143, 191, 191])
    reject_utf8([244, 144, 128, 128])
    reject_utf8([244, 143, 191])
    reject_utf8([245, 128, 128, 128])
    reject_utf8([255])
    # Concatenation is valid UTF-8, but neither value is independently valid.
    with assert_raises():
        _ = StringColumn(BinaryColumn([0, 1, 2], [194, 128]))


def test_scalar_boundaries_and_storage_validation() raises:
    var bytes: List[UInt8] = [
        0,
        127,
        194,
        128,
        223,
        191,
        224,
        160,
        128,
        237,
        159,
        191,
        238,
        128,
        128,
        239,
        191,
        191,
        240,
        144,
        128,
        128,
        244,
        143,
        191,
        191,
    ]
    var size = len(bytes)
    var column = StringColumn(BinaryColumn([0, size], bytes^))
    assert_equal(column.value(0).byte_length(), size)
    with assert_raises():
        _ = StringColumn(BinaryColumn([0, 1], [65], fixed_width=1))
    with assert_raises():
        _ = StringColumn(BinaryColumn([0, -1], List[UInt8]()))
    with assert_raises():
        _ = StringColumn(BinaryColumn([0, 2], [65]))
    with assert_raises():
        _ = StringColumn(BinaryColumn([0, 0], [65]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
