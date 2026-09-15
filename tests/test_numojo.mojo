"""Direct decode correctness, corruption rejection, and allocation identity."""
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from std.memory import bitcast
from std.sys import size_of
from numojo.routines.creation import empty
from pyroquet.numojo_io import (
    NumojoUInt32Column,
    NumericColumn,
    _decode_plain_page,
    _plain_value,
    _matches_numeric,
)
from pyroquet.format import PageHeader, SchemaElement


def _header(v2: Bool = False) -> PageHeader:
    var h = PageHeader()
    h.page_type = 3 if v2 else 0
    h.encoding = 0
    h.num_values = 3
    h.definition_level_encoding = 3
    h.repetition_level_encoding = 3
    h.definition_levels_byte_length = 2
    h.repetition_levels_byte_length = 0
    h.num_nulls = 1
    return h


def _make_column() raises -> NumojoUInt32Column:
    var values = empty[DType.uint32]([3])
    var address = Int(values.unsafe_ptr())
    var bitmap: List[UInt8] = [0]
    # Three hybrid bit-packed definition levels: present, null, present.
    var bytes: List[UInt8] = [2, 0, 0, 0, 3, 5, 0, 0, 0, 0, 255, 255, 255, 255]
    assert_equal(
        _decode_plain_page[DType.uint32](
            bytes, _header(), True, values, bitmap, 0
        ),
        1,
    )
    assert_equal(Int(values.unsafe_ptr()), address)
    var result = NumojoUInt32Column(values^, bitmap^, "value", 1)
    assert_equal(Int(result.values().unsafe_ptr()), address)
    return result^


def test_direct_allocation_and_returned_lifetime() raises:
    var column = _make_column()
    var address = Int(column.values().unsafe_ptr())
    var moved = column^
    assert_equal(Int(moved.values().unsafe_ptr()), address)
    assert_equal(moved.value(0).value(), UInt32(0))
    assert_false(Bool(moved.value(1)))
    assert_equal(moved.value(2).value(), UInt32.MAX)
    assert_equal(moved.values().unsafe_ptr()[unsafe_offset=1], UInt32(0))
    assert_equal(moved.validity()[0], UInt8(5))
    assert_equal(moved.null_count(), 1)
    with assert_raises():
        _ = moved.value(3)


def test_page_boundaries_share_one_bitmap_byte() raises:
    var values = empty[DType.uint32]([6])
    var bitmap: List[UInt8] = [0]
    var bytes: List[UInt8] = [3, 5, 1, 0, 0, 0, 2, 0, 0, 0]
    assert_equal(
        _decode_plain_page[DType.uint32](
            bytes, _header(True), True, values, bitmap, 0
        ),
        1,
    )
    assert_equal(
        _decode_plain_page[DType.uint32](
            bytes, _header(True), True, values, bitmap, 3
        ),
        1,
    )
    assert_equal(bitmap[0], UInt8(45))
    assert_equal(values.unsafe_ptr()[unsafe_offset=5], UInt32(2))


def test_required_plain_and_exact_length() raises:
    var values = empty[DType.uint32]([3])
    var bitmap = List[UInt8]()
    var bytes: List[UInt8] = [0, 0, 0, 128, 255, 255, 255, 255, 0, 0, 0, 0]
    assert_equal(
        _decode_plain_page[DType.uint32](
            bytes, _header(), False, values, bitmap, 0
        ),
        0,
    )
    assert_equal(values.unsafe_ptr()[unsafe_offset=0], UInt32(2147483648))
    assert_equal(values.unsafe_ptr()[unsafe_offset=1], UInt32.MAX)
    bytes.append(0)
    with assert_raises():
        _ = _decode_plain_page[DType.uint32](
            bytes, _header(), False, values, bitmap, 0
        )


def test_rle_and_malformed_level_streams() raises:
    var values = empty[DType.uint32]([3])
    var bitmap: List[UInt8] = [0]
    var h = _header(True)
    h.num_nulls = 3
    var all_null: List[UInt8] = [6, 0]
    assert_equal(
        _decode_plain_page[DType.uint32](all_null, h, True, values, bitmap, 0),
        3,
    )
    var invalid: List[UInt8] = [6, 2]
    with assert_raises():
        _ = _decode_plain_page[DType.uint32](
            invalid, h, True, values, bitmap, 0
        )
    var overflow: List[UInt8] = [255, 255, 255, 255, 31]
    h.definition_levels_byte_length = 5
    with assert_raises():
        _ = _decode_plain_page[DType.uint32](
            overflow, h, True, values, bitmap, 0
        )
    h = _header(True)
    h.num_nulls = 0
    with assert_raises():
        _ = _decode_plain_page[DType.uint32](
            all_null, h, True, values, bitmap, 0
        )
    with assert_raises():
        _ = _decode_plain_page[DType.uint32](
            all_null, h, True, values, bitmap, 1
        )


def test_column_validity_invariants() raises:
    with assert_raises():
        var v = empty[DType.uint32]([3])
        _ = NumojoUInt32Column(v^, List[UInt8](), "x", 1)
    with assert_raises():
        var v = empty[DType.uint32]([3])
        _ = NumojoUInt32Column(v^, [UInt8(255)], "x", 0)
    with assert_raises():
        var v = empty[DType.uint32]([3])
        _ = NumojoUInt32Column(v^, [UInt8(5)], "x", 0)


def _numeric_case[dtype: DType]() raises:
    comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
    var bytes: List[UInt8] = [3, 5]
    for _ in range(2):
        bytes.append(1)
        for _ in range(1, width):
            bytes.append(0)
    var values = empty[dtype]([6])
    var address = Int(values.unsafe_ptr())
    var bitmap: List[UInt8] = [0]
    for page in range(2):
        assert_equal(
            _decode_plain_page[dtype](
                bytes, _header(True), True, values, bitmap, page * 3
            ),
            1,
        )
    var column = NumericColumn[dtype](values^, bitmap^, "x", 2)
    var moved = column^
    assert_equal(Int(moved.values().unsafe_ptr()), address)
    assert_equal(moved.validity()[0], UInt8(45))
    assert_false(Bool(moved.value(1)))
    assert_equal(moved.values().unsafe_ptr()[unsafe_offset=1], Scalar[dtype](0))
    bytes.append(0)
    var dest = empty[dtype]([3])
    var bits: List[UInt8] = [0]
    with assert_raises():
        _ = _decode_plain_page[dtype](bytes, _header(True), True, dest, bits, 0)
    var h = _header(True)
    h.num_nulls = 3
    bits[0] = 0
    var nulls: List[UInt8] = [6, 0]
    assert_equal(_decode_plain_page[dtype](nulls, h, True, dest, bits, 0), 3)
    var empty_values = empty[dtype]([0])
    var empty_column = NumericColumn[dtype](
        empty_values^, List[UInt8](), "x", 0
    )
    assert_equal(empty_column.size(), 0)


def test_all_numeric_allocations_and_pages() raises:
    comptime types = (
        DType.int8,
        DType.uint8,
        DType.int16,
        DType.uint16,
        DType.int32,
        DType.uint32,
        DType.int64,
        DType.uint64,
        DType.float32,
        DType.float64,
    )
    comptime for index in range(len(types)):
        comptime dtype = types[index]
        _numeric_case[dtype]()


def test_checked_narrowing_and_signed_wire() raises:
    var minus_one: List[UInt8] = [255, 255, 255, 255]
    assert_equal(_plain_value[DType.int8](minus_one, 0), Int8(-1))
    assert_equal(_plain_value[DType.int16](minus_one, 0), Int16(-1))
    assert_equal(_plain_value[DType.int32](minus_one, 0), Int32(-1))
    comptime types = (DType.uint8, DType.uint16)
    comptime for index in range(len(types)):
        comptime dtype = types[index]
        with assert_raises():
            _ = _plain_value[dtype](minus_one, 0)
    var plus128: List[UInt8] = [128, 0, 0, 0]
    with assert_raises():
        _ = _plain_value[DType.int8](plus128, 0)
    var minus129: List[UInt8] = [127, 255, 255, 255]
    with assert_raises():
        _ = _plain_value[DType.int8](minus129, 0)
    var plus32768: List[UInt8] = [0, 128, 0, 0]
    with assert_raises():
        _ = _plain_value[DType.int16](plus32768, 0)
    var minus32769: List[UInt8] = [255, 127, 255, 255]
    with assert_raises():
        _ = _plain_value[DType.int16](minus32769, 0)
    var plus256: List[UInt8] = [0, 1, 0, 0]
    with assert_raises():
        _ = _plain_value[DType.uint8](plus256, 0)
    var plus65536: List[UInt8] = [0, 0, 1, 0]
    with assert_raises():
        _ = _plain_value[DType.uint16](plus65536, 0)


def test_float_wire_bits() raises:
    var patterns32: List[UInt32] = [
        0,
        0x80000000,
        0x7F800000,
        0xFF800000,
        0x7FC12345,
        0x7F800001,
        1,
    ]
    for pattern in patterns32:
        var bytes = List[UInt8]()
        for j in range(4):
            bytes.append(UInt8(pattern >> UInt32(j * 8)))
        assert_equal(
            bitcast[DType.uint32](_plain_value[DType.float32](bytes, 0)),
            pattern,
        )
    var patterns64: List[UInt64] = [
        0,
        0x8000000000000000,
        0x7FF0000000000000,
        0xFFF0000000000000,
        0x7FF8123456789ABC,
        0x7FF0000000000001,
        1,
    ]
    for pattern in patterns64:
        var bytes = List[UInt8]()
        for j in range(8):
            bytes.append(UInt8(pattern >> UInt64(j * 8)))
        assert_equal(
            bitcast[DType.uint64](_plain_value[DType.float64](bytes, 0)),
            pattern,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
