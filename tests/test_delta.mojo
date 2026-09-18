"""Spec-derived delta controls; Encodings.md Delta Encoding, including padding."""
from std.testing import assert_equal, assert_raises, TestSuite
from pyroquet.format.delta import _DeltaDecoder
from pyroquet.numojo_io import _delta_value, _decode_numeric_page
from pyroquet.format.pages import PageHeader
from numojo.routines.creation import empty


def _varint(mut data: List[UInt8], var value: UInt64):
    while value >= 128:
        data.append(UInt8(value & 127) | 128)
        value >>= 7
    data.append(UInt8(value))


def _constant(count: Int, first: UInt64, minimum: UInt64) -> List[UInt8]:
    var data: List[UInt8] = [128, 1, 4]
    _varint(data, UInt64(count))
    _varint(data, first)
    var remaining = count - 1
    while remaining > 0:
        _varint(data, minimum)
        data.extend([0, 0, 0, 0])
        remaining -= min(128, remaining)
    return data^


def test_constant_decreasing_multiblock_and_wrapping() raises:
    var counts: List[Int] = [0, 1, 2, 32, 33, 34, 128, 129, 130, 513]
    for count in counts:
        var data = _constant(count, 200, 3)  # first 100, delta -2
        var decoder = _DeltaDecoder[32](data, 0, len(data), count)
        for i in range(count):
            assert_equal(decoder.next(data), UInt64(UInt32(100 - 2 * i)))
        decoder.finish()
    # max signed -> min signed and unsigned max -> zero wrap at physical width.
    var data = _constant(4, 0xFFFFFFFE, 2)
    var decoder = _DeltaDecoder[32](data, 0, len(data), 4)
    for i in range(4):
        assert_equal(decoder.next(data), UInt64(0x7FFFFFFF) + UInt64(i))
    decoder.finish()
    data = _constant(4, 1, 2)
    decoder = _DeltaDecoder[32](data, 0, len(data), 4)
    assert_equal(decoder.next(data), UInt64(0xFFFFFFFF))
    for i in range(3):
        assert_equal(decoder.next(data), UInt64(i))
    decoder.finish()
    data = _constant(4, 0xFFFFFFFFFFFFFFFE, 2)
    var wide = _DeltaDecoder[64](data, 0, len(data), 4)
    for i in range(4):
        assert_equal(wide.next(data), UInt64(0x7FFFFFFFFFFFFFFF) + UInt64(i))
    wide.finish()
    data = _constant(4, 1, 2)
    wide = _DeltaDecoder[64](data, 0, len(data), 4)
    assert_equal(wide.next(data), UInt64.MAX)
    for i in range(3):
        assert_equal(wide.next(data), UInt64(i))
    wide.finish()


def _packed(width: Int, count: Int = 3) -> List[UInt8]:
    # One partial miniblock; all encoded adjustments are all-ones. Both
    # unused width bytes and unused value bits deliberately contain garbage.
    var data: List[UInt8] = [
        128,
        1,
        4,
        UInt8(count),
        0,
        1,
        UInt8(width),
        255,
        254,
        253,
    ]
    for _ in range(width * 4):
        data.append(255)
    return data^


def test_all_widths_arbitrary_padding_and_minimum_wrap() raises:
    for width in range(65):
        var data = _packed(width)
        var decoder = _DeltaDecoder[64](data, 0, len(data), 3)
        var mask = UInt64.MAX
        if width < 64:
            mask = (UInt64(1) << UInt64(width)) - 1
        assert_equal(decoder.next(data), UInt64(0))
        assert_equal(decoder.next(data), mask - 1)
        assert_equal(decoder.next(data), (mask - 1) * 2)
        decoder.finish()
        if width <= 32:
            var small = _DeltaDecoder[32](data, 0, len(data), 3)
            assert_equal(small.next(data), UInt64(0))
            assert_equal(small.next(data), UInt64(UInt32(mask - 1)))
            assert_equal(small.next(data), UInt64(UInt32((mask - 1) * 2)))
            small.finish()


def _consume(data: List[UInt8], count: Int) raises:
    var decoder = _DeltaDecoder[32](data, 0, len(data), count)
    for _ in range(count):
        _ = decoder.next(data)
    decoder.finish()


def test_truncation_parameters_count_width_and_extra_payload() raises:
    var valid = _packed(32)
    for length in range(len(valid)):
        var truncated = List[UInt8]()
        truncated.extend(Span(valid)[:length])
        with assert_raises():
            _consume(truncated, 3)
    var data = valid.copy()
    data.append(0)
    with assert_raises():
        _consume(data, 3)
    var indexes: List[Int] = [0, 2, 3, 6]
    var invalid: List[UInt8] = [127, 3, 4, 33]
    for i in range(len(indexes)):
        data = valid.copy()
        data[indexes[i]] = invalid[i]
        with assert_raises():
            _consume(data, 3)
    data = [128, 128, 128, 128, 16]
    with assert_raises():
        _consume(data, 3)
    data = [128, 1, 4, 1, 255, 255, 255, 255, 16]
    with assert_raises():
        _consume(data, 1)
    var empty = List[UInt8]()
    _consume(empty, 0)
    with assert_raises():
        _consume(valid, -1)


def test_narrow_ranges_and_nullable_integration() raises:
    assert_equal(_delta_value[DType.int8](0xFFFFFFFF), Int8(-1))
    assert_equal(_delta_value[DType.uint8](255), UInt8(255))
    with assert_raises():
        _ = _delta_value[DType.int8](128)
    with assert_raises():
        _ = _delta_value[DType.int8](0xFFFFFF7F)
    with assert_raises():
        _ = _delta_value[DType.uint8](256)
    var h = PageHeader()
    h.page_type = 3
    h.encoding = 5
    h.num_values = 8
    h.num_nulls = 4
    h.definition_levels_byte_length = 2
    h.repetition_levels_byte_length = 0
    var data: List[UInt8] = [3, 0x55]
    var encoded = _constant(4, 14, 2)
    data.extend(Span(encoded))
    var values = empty[DType.int32]([10])
    var bitmap = List[UInt8](length=2, fill=0)
    var dictionary = List[Int32]()
    assert_equal(
        _decode_numeric_page[DType.int32](
            data, h, True, values, bitmap, 1, dictionary, False
        ),
        4,
    )
    for i in range(8):
        assert_equal(
            values.unsafe_ptr()[unsafe_offset=i + 1],
            Int32(7 + i // 2 if i % 2 == 0 else 0),
        )
    h.num_nulls = 8
    data = [16, 0]
    bitmap = List[UInt8](length=2, fill=0)
    assert_equal(
        _decode_numeric_page[DType.int32](
            data, h, True, values, bitmap, 1, dictionary, False
        ),
        8,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
