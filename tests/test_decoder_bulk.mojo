"""Bulk numeric/validity regression tests through validated page decoding."""
from std.memory import bitcast
from std.sys import size_of
from std.testing import assert_equal, assert_raises, TestSuite
from numojo.routines.creation import empty
from pyroquet.format import PageHeader
from pyroquet.format.flat_pages import _flat_page_values
from pyroquet.numojo_io import _decode_plain_page


def _header(rows: Int, levels: Int, nulls: Int = 0) -> PageHeader:
    var h = PageHeader()
    h.page_type = 3
    h.encoding = 0
    h.num_values = rows
    h.num_nulls = nulls
    h.definition_levels_byte_length = levels
    h.repetition_levels_byte_length = 0
    h.definition_level_encoding = 3
    h.repetition_level_encoding = 3
    return h


def _append_bits(mut data: List[UInt8], bits: UInt64, width: Int):
    for j in range(width):
        data.append(UInt8(bits >> UInt64(j * 8)))


def _assert_bits[dtype: DType](value: Scalar[dtype], bits: UInt64) raises:
    comptime if dtype == DType.float32:
        assert_equal(bitcast[DType.uint32](value), UInt32(bits))
    elif dtype == DType.float64:
        assert_equal(bitcast[DType.uint64](value), bits)
    else:
        assert_equal(value, Scalar[dtype](bits))


def _numeric_paths[dtype: DType]() raises:
    comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
    # Required, optional RLE all-present, optional packed all-present, and
    # sparse-null pages, plus V1 framing, share payload bits and output guards.
    for mode in range(5):
        var body = List[UInt8]()
        var levels = 0
        var nulls = 0
        if mode == 1:
            body = [34, 1]
            levels = 2
        elif mode == 2 or mode == 3:
            body = [7, 0, 0, 0]
            levels = 4
            for i in range(17):
                if mode == 2 or i % 3 != 1:
                    body[1 + i // 8] |= UInt8(1) << UInt8(i % 8)
                else:
                    nulls += 1
        elif mode == 4:
            body = [2, 0, 0, 0, 34, 1]
            levels = 2
        for i in range(17):
            if mode != 3 or i % 3 != 1:
                _append_bits(body, UInt64(i + 1), width)
        var values = empty[dtype]([25])
        values.fill(Scalar[dtype](42))
        var address = Int(values.unsafe_ptr())
        # Preserve preceding and following page bits sharing the same bytes.
        var bitmap: List[UInt8] = [5, 0, 0xA0, 0xFF]
        var h = _header(17, levels, nulls)
        if mode == 4:
            h.page_type = 0
        assert_equal(
            _decode_plain_page[dtype](body, h, mode != 0, values, bitmap, 3),
            nulls,
        )
        assert_equal(Int(values.unsafe_ptr()), address)
        for i in range(25):
            if i < 3 or i >= 20:
                assert_equal(
                    values.unsafe_ptr()[unsafe_offset=i], Scalar[dtype](42)
                )
            else:
                var row = i - 3
                var expected = UInt64(row + 1)
                if mode == 3 and row % 3 == 1:
                    expected = 0
                _assert_bits[dtype](
                    values.unsafe_ptr()[unsafe_offset=i], expected
                )
        for i in range(32):
            var expected = i == 0 or i == 2 or i == 21 or i == 23 or i >= 24
            if mode != 0 and i >= 3 and i < 20:
                expected = mode != 3 or (i - 3) % 3 != 1
            assert_equal(
                Bool(bitmap[i // 8] & (UInt8(1) << UInt8(i % 8))), expected
            )


def test_all_numeric_paths_and_output_guards() raises:
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
    comptime for i in range(len(types)):
        _numeric_paths[types[i]]()


def _float_paths[dtype: DType](patterns: List[UInt64]) raises:
    comptime width = size_of[Scalar[dtype]]()
    for nullable in range(2):
        var rows = len(patterns) * (nullable + 1)
        var body = List[UInt8]()
        var levels = 0
        if nullable:
            var groups = (rows + 7) // 8
            body.append(UInt8(groups * 2 + 1))
            for _ in range(groups):
                body.append(0x55)
            levels = 1 + groups
        for bits in patterns:
            _append_bits(body, bits, width)
        var values = empty[dtype]([rows])
        var bitmap = List[UInt8]()
        for _ in range((rows + 7) // 8):
            bitmap.append(0)
        assert_equal(
            _decode_plain_page[dtype](
                body,
                _header(rows, levels, len(patterns) * nullable),
                Bool(nullable),
                values,
                bitmap,
                0,
            ),
            len(patterns) * nullable,
        )
        for i in range(rows):
            var expected = UInt64(0)
            if nullable == 0 or i % 2 == 0:
                expected = patterns[i // (nullable + 1)]
            _assert_bits[dtype](values.unsafe_ptr()[unsafe_offset=i], expected)


def test_bulk_and_scatter_preserve_float_bits() raises:
    _float_paths[DType.float32](
        [
            UInt64(0),
            0x80000000,
            0x7F800000,
            0xFF800000,
            0x7FC12345,
            0x7F800001,
            1,
        ]
    )
    _float_paths[DType.float64](
        [
            UInt64(0),
            0x8000000000000000,
            0x7FF0000000000000,
            0xFFF0000000000000,
            0x7FF8123456789ABC,
            0x7FF0000000000001,
            1,
        ]
    )


def test_run_validity_all_offsets_lengths_and_neighbor_bits() raises:
    for offset in range(8):
        for count in range(1, 66):
            for present in range(2):
                var body = List[UInt8]()
                var header = count * 2
                if header >= 128:
                    body.append(UInt8(header & 127) | 128)
                    body.append(UInt8(header >> 7))
                else:
                    body.append(UInt8(header))
                body.append(UInt8(present))
                var bitmap = List[UInt8]()
                for _ in range(11):
                    bitmap.append(0)
                for i in range(88):
                    if (i < offset or i >= offset + count) and i % 2 == 0:
                        bitmap[i // 8] |= UInt8(1) << UInt8(i % 8)
                var framing = _flat_page_values(
                    body,
                    _header(count, len(body), count * (1 - present)),
                    True,
                    bitmap,
                    offset,
                )
                assert_equal(framing[0], len(body))
                assert_equal(framing[1], count * present)
                for i in range(88):
                    var expected = i % 2 == 0
                    if i >= offset and i < offset + count:
                        expected = Bool(present)
                    assert_equal(
                        Bool(bitmap[i // 8] & (UInt8(1) << UInt8(i % 8))),
                        expected,
                    )


def test_packed_validity_offsets_padding_and_mixed_runs() raises:
    for offset in range(8):
        for rows in range(9, 17):
            # Three present, two absent, then 9..16 packed levels; final
            # padding is deliberately nonzero and must not escape into output.
            var body: List[UInt8] = [6, 1, 4, 0, 5, 0xA5, 0xF3]
            var expected: List[UInt8] = [1, 1, 1, 0, 0]
            var present = 3
            for i in range(rows):
                var bit = (body[5 + i // 8] >> UInt8(i % 8)) & 1
                expected.append(bit)
                present += Int(bit)
            var bitmap: List[UInt8] = [0, 0, 0, 0, 0]
            # Adjacent-page sentinels in both shared edge bytes.
            if offset:
                bitmap[0] = UInt8(1) << UInt8(offset - 1)
            var stop = offset + len(expected)
            bitmap[stop // 8] |= UInt8(1) << UInt8(stop % 8)
            var framing = _flat_page_values(
                body,
                _header(len(expected), len(body), len(expected) - present),
                True,
                bitmap,
                offset,
            )
            assert_equal(framing[1], present)
            for i in range(40):
                var valid = i == stop or (offset != 0 and i == offset - 1)
                if i >= offset and i < stop:
                    valid = Bool(expected[i - offset])
                assert_equal(
                    Bool(bitmap[i // 8] & (UInt8(1) << UInt8(i % 8))), valid
                )


def _reject_all_valid_claim(var body: List[UInt8], rows: Int) raises:
    var h = _header(rows, len(body))
    # Correct value payload size must never allow malformed levels through.
    for _ in range(rows):
        _append_bits(body, 7, 4)
    var values = empty[DType.uint32]([rows])
    var bitmap: List[UInt8] = [0, 0, 0]
    with assert_raises():
        _ = _decode_plain_page[DType.uint32](body, h, True, values, bitmap, 0)


def test_all_valid_metadata_does_not_bypass_level_validation() raises:
    _reject_all_valid_claim([UInt8(6), 0], 3)  # Contradictory null count.
    _reject_all_valid_claim([UInt8(6), 2], 3)  # Invalid repeated level.
    _reject_all_valid_claim([UInt8(8), 1], 3)  # RLE count exceeds rows.
    _reject_all_valid_claim([UInt8(0), 1], 3)  # Empty run.
    _reject_all_valid_claim([UInt8(128)], 3)  # Truncated varint.
    _reject_all_valid_claim([UInt8(255), 255, 255, 255, 16], 3)
    _reject_all_valid_claim([UInt8(5), 255, 255], 3)  # Excess padding.
    _reject_all_valid_claim([UInt8(3), 255, 2, 1], 3)  # Trailing run.


def test_narrow_plain_still_rejects_out_of_range_all_present() raises:
    comptime types = (DType.int8, DType.uint8, DType.int16, DType.uint16)
    comptime for i in range(len(types)):
        comptime dtype = types[i]
        var values = empty[dtype]([1])
        var bitmap: List[UInt8] = [0]
        var body: List[UInt8] = [2, 1]
        _append_bits(body, UInt64(Scalar[dtype].MAX) + 1, 4)
        with assert_raises():
            _ = _decode_plain_page[dtype](
                body, _header(1, 2), True, values, bitmap, 0
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
