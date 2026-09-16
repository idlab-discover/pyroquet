"""Dictionary run/batch integration, sparse fallback, and exact floating bits."""
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite
from numojo.routines.creation import empty
from pyroquet.format import PageHeader
from pyroquet.numojo_io import _decode_numeric_page


def _header(count: Int, levels: Int = 0, nulls: Int = 0) -> PageHeader:
    var h = PageHeader()
    h.page_type = 3
    h.encoding = 8
    h.num_values = count
    h.definition_levels_byte_length = levels
    h.repetition_levels_byte_length = 0
    h.num_nulls = nulls
    return h


def _packed_ids() -> List[UInt8]:
    # 65 actual alternating IDs, followed by seven out-of-dictionary padding
    # IDs. Padding is encoded and bounded, but is not a dictionary lookup.
    var data: List[UInt8] = [2, 19]
    for _ in range(16):
        data.append(0x44)
    data.append(0xFC)
    data.append(0xFF)
    return data^


def _assert_bits[
    dtype: DType
](actual: Scalar[dtype], expected: Scalar[dtype]) raises:
    comptime if dtype == DType.float32:
        assert_equal(
            bitcast[DType.uint32](actual), bitcast[DType.uint32](expected)
        )
    elif dtype == DType.float64:
        assert_equal(
            bitcast[DType.uint64](actual), bitcast[DType.uint64](expected)
        )
    else:
        assert_equal(actual, expected)


def _typed_dictionary_cases[dtype: DType]() raises:
    var dictionary = List[Scalar[dtype]]()
    comptime if dtype == DType.float32:
        dictionary.append(bitcast[dtype](UInt32(0x80000000)))
        dictionary.append(bitcast[dtype](UInt32(0x7FC12345)))
    elif dtype == DType.float64:
        dictionary.append(bitcast[dtype](UInt64(0x8000000000000000)))
        dictionary.append(bitcast[dtype](UInt64(0x7FF8123456789ABC)))
    else:
        dictionary.append(Scalar[dtype].MIN)
        dictionary.append(Scalar[dtype].MAX)
    var packed = _packed_ids()
    # Validated all-present levels, a 129-ID repeated run, then 65 packed IDs.
    var data: List[UInt8] = [0x84, 3, 1, 2, 0x82, 2, 1]
    data.extend(Span(packed)[1:])
    var values = empty[dtype]([196])
    var pointer = values.unsafe_ptr()
    pointer[unsafe_offset=0] = Scalar[dtype](7)
    pointer[unsafe_offset=195] = Scalar[dtype](7)
    var bitmap = List[UInt8](length=25, fill=0)
    var h = _header(194, 3)
    for encoding in range(2):
        h.encoding = 2 if encoding == 0 else 8
        assert_equal(
            _decode_numeric_page[dtype](
                data, h, True, values, bitmap, 1, dictionary, True
            ),
            0,
        )
        for i in range(194):
            var index = 1 if i < 129 else (i - 129) % 2
            _assert_bits[dtype](pointer[unsafe_offset=i + 1], dictionary[index])
        _assert_bits[dtype](pointer[unsafe_offset=0], Scalar[dtype](7))
        _assert_bits[dtype](pointer[unsafe_offset=195], Scalar[dtype](7))
        assert_equal(bitmap[0], UInt8(254))
        assert_equal(bitmap[24], UInt8(7))

    # 73 rows contain 65 actual IDs and eight nulls. The bit-packed level
    # stream and output offset make nulls cross byte and 64-ID boundaries.
    var sparse: List[UInt8] = [21]
    for _ in range(10):
        sparse.append(0)
    for i in range(73):
        if i % 9 != 8:
            sparse[1 + i // 8] |= UInt8(1) << UInt8(i % 8)
    sparse.extend(Span(packed))
    var sparse_values = empty[dtype]([75])
    var sparse_pointer = sparse_values.unsafe_ptr()
    sparse_pointer[unsafe_offset=0] = Scalar[dtype](7)
    sparse_pointer[unsafe_offset=74] = Scalar[dtype](7)
    bitmap = List[UInt8](length=10, fill=0)
    assert_equal(
        _decode_numeric_page[dtype](
            sparse,
            _header(73, 11, 8),
            True,
            sparse_values,
            bitmap,
            1,
            dictionary,
            True,
        ),
        8,
    )
    var index = 0
    for i in range(73):
        var present = i % 9 != 8
        assert_equal(
            Bool(bitmap[(i + 1) // 8] & (UInt8(1) << UInt8((i + 1) % 8))),
            present,
        )
        if present:
            _assert_bits[dtype](
                sparse_pointer[unsafe_offset=i + 1], dictionary[index % 2]
            )
            index += 1
        else:
            _assert_bits[dtype](
                sparse_pointer[unsafe_offset=i + 1], Scalar[dtype](0)
            )
    assert_equal(index, 65)
    _assert_bits[dtype](sparse_pointer[unsafe_offset=0], Scalar[dtype](7))
    _assert_bits[dtype](sparse_pointer[unsafe_offset=74], Scalar[dtype](7))


def test_dictionary_runs_batches_and_sparse_all_numeric_types() raises:
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
        _typed_dictionary_cases[types[index]]()


def test_invalid_actual_ids_and_valid_unused_padding() raises:
    var dictionary: List[UInt32] = [11, 22]
    var values = empty[DType.uint32]([65])
    var bitmap = List[UInt8]()
    var h = _header(65)
    var data = _packed_ids()
    assert_equal(
        _decode_numeric_page[DType.uint32](
            data, h, False, values, bitmap, 0, dictionary, True
        ),
        0,
    )
    for i in range(65):
        assert_equal(values.unsafe_ptr()[unsafe_offset=i], dictionary[i % 2])
    # Invalid IDs at both ends of the first batch and in the following batch.
    for invalid in range(3):
        var index = 0 if invalid == 0 else (63 if invalid == 1 else 64)
        data = _packed_ids()
        data[2 + index // 4] |= UInt8(3) << UInt8((index % 4) * 2)
        with assert_raises():
            _ = _decode_numeric_page[DType.uint32](
                data, h, False, values, bitmap, 0, dictionary, True
            )
    h.num_values = 1
    data = [32, 2, 255, 255, 255, 255]
    with assert_raises():
        _ = _decode_numeric_page[DType.uint32](
            data, h, False, values, bitmap, 0, dictionary, True
        )


def test_empty_dictionary_zero_present_and_trailing_rejection() raises:
    var dictionary = List[UInt32]()
    var values = empty[DType.uint32]([9])
    var bitmap: List[UInt8] = [0, 0]
    var data: List[UInt8] = [18, 0, 0]
    assert_equal(
        _decode_numeric_page[DType.uint32](
            data, _header(9, 2, 9), True, values, bitmap, 0, dictionary, True
        ),
        9,
    )
    for i in range(9):
        assert_equal(values.unsafe_ptr()[unsafe_offset=i], UInt32(0))
    # Zero-row all-present path must still finish and reject trailing ID data.
    data = [0]
    assert_equal(
        _decode_numeric_page[DType.uint32](
            data, _header(0), False, values, bitmap, 0, dictionary, True
        ),
        0,
    )
    data.append(2)
    with assert_raises():
        _ = _decode_numeric_page[DType.uint32](
            data, _header(0), False, values, bitmap, 0, dictionary, True
        )


def _wide_packed_ids(width: Int, invalid: Int = -1) -> List[UInt8]:
    var data: List[UInt8] = [UInt8(width), 19]
    for _ in range(width * 9):
        data.append(0)
    var mask = UInt32(0xFFFFFFFF)
    if width < 32:
        mask = (UInt32(1) << UInt32(width)) - 1
    for i in range(72):
        # Cardinality one: every nonzero ID is invalid, but unused final
        # padding must never be checked against the dictionary cardinality.
        var value = mask if i >= 65 or i == invalid else UInt32(0)
        for bit in range(width):
            var pos = i * width + bit
            data[2 + pos // 8] |= UInt8((value >> UInt32(bit)) & 1) << UInt8(
                pos % 8
            )
    return data^


def test_all_packed_widths_invalid_consumed_ids_and_output_guards() raises:
    var dictionary: List[UInt32] = [0x12345678]
    var bitmap = List[UInt8]()
    var values = empty[DType.uint32]([67])
    var pointer = values.unsafe_ptr()
    var invalid_positions: List[Int] = [0, 31, 63, 64]
    for width in range(33):
        var data = _wide_packed_ids(width)
        pointer[unsafe_offset=0] = 0xA5A5A5A5
        pointer[unsafe_offset=66] = 0xA5A5A5A5
        assert_equal(
            _decode_numeric_page[DType.uint32](
                data, _header(65), False, values, bitmap, 1, dictionary, True
            ),
            0,
        )
        for i in range(65):
            assert_equal(pointer[unsafe_offset=i + 1], dictionary[0])
        assert_equal(pointer[unsafe_offset=0], UInt32(0xA5A5A5A5))
        assert_equal(pointer[unsafe_offset=66], UInt32(0xA5A5A5A5))
        if width == 0:
            var empty_dictionary = List[UInt32]()
            with assert_raises():
                _ = _decode_numeric_page[DType.uint32](
                    data,
                    _header(65),
                    False,
                    values,
                    bitmap,
                    1,
                    empty_dictionary,
                    True,
                )
        else:
            for invalid in invalid_positions:
                data = _wide_packed_ids(width, invalid)
                with assert_raises():
                    _ = _decode_numeric_page[DType.uint32](
                        data,
                        _header(65),
                        False,
                        values,
                        bitmap,
                        1,
                        dictionary,
                        True,
                    )
                assert_equal(pointer[unsafe_offset=0], UInt32(0xA5A5A5A5))
                assert_equal(pointer[unsafe_offset=66], UInt32(0xA5A5A5A5))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
