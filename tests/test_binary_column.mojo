from std.testing import TestSuite, assert_equal, assert_raises, assert_false
from pyroquet.binary_column import BinaryColumn


def test_empty_null_and_raw_bytes() raises:
    var offsets: List[Int] = [0, 0, 0, 3]
    var data: List[UInt8] = [0, 255, 128]
    var validity: List[UInt8] = [5]
    var column = BinaryColumn(offsets^, data^, validity^)
    assert_equal(len(column), 3)
    assert_equal(column.null_count(), 1)
    assert_equal(len(column.value(0)), 0)
    assert_false(column.is_valid(1))
    with assert_raises():
        _ = column.value(1)
    assert_equal(column.value(2)[0], UInt8(0))
    assert_equal(column.value(2)[1], UInt8(255))
    assert_equal(column.value(2)[2], UInt8(128))
    var shared = column.copy()
    assert_equal(
        Int(shared.value(2).unsafe_ptr()), Int(column.value(2).unsafe_ptr())
    )


def test_fixed_width_and_ranges() raises:
    var offsets: List[Int] = [0, 2, 2, 4]
    var data: List[UInt8] = [0, 255, 128, 0]
    var validity: List[UInt8] = [5]
    var column = BinaryColumn(offsets^, data^, validity^, fixed_width=2)
    assert_equal(column.fixed_width(), 2)
    with assert_raises():
        _ = column.value(-1)
    with assert_raises():
        _ = column.value(3)
    with assert_raises():
        _ = BinaryColumn([0, 1], [1], fixed_width=2)


def test_invalid_offsets_and_validity() raises:
    with assert_raises():
        _ = BinaryColumn(List[Int](), List[UInt8]())
    with assert_raises():
        _ = BinaryColumn([1], List[UInt8]())
    with assert_raises():
        _ = BinaryColumn([0, -1], List[UInt8]())
    with assert_raises():
        _ = BinaryColumn([0, Int.MAX], List[UInt8]())
    with assert_raises():
        _ = BinaryColumn([0, 0], [1])
    with assert_raises():
        _ = BinaryColumn([0, 1], [1], [0])
    with assert_raises():
        _ = BinaryColumn([0, 0], List[UInt8](), [2])
    with assert_raises():
        _ = BinaryColumn([0, 0], List[UInt8](), [0, 0])
    with assert_raises():
        _ = BinaryColumn([0], List[UInt8](), fixed_width=-1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_builder_budget_and_consume() raises:
    from pyroquet.binary_column import BinaryBuilder

    var builder = BinaryBuilder(max_bytes=2)
    var bytes: List[UInt8] = [0, 255]
    builder.append(Span(bytes))
    with assert_raises():
        builder.append(Span(bytes))
    builder.append_null()
    var empty = List[UInt8]()
    builder.append(Span(empty))
    var column = builder^.freeze()
    assert_equal(len(column), 3)
    assert_equal(column.null_count(), 1)
    assert_equal(len(column.value(2)), 0)
    assert_equal(column.value(0)[1], UInt8(255))
