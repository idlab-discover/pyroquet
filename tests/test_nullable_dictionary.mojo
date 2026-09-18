"""Nullable dictionary batches: tails, masks, bit preservation, and failures."""
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite
from numojo.routines.creation import empty
from pyroquet.format import PageHeader
from pyroquet.numojo_io import _decode_numeric_page
from test_dictionary_gather import _assert_bits


def _varint(mut data: List[UInt8], value: Int):
    var remaining = value
    while remaining >= 128:
        data.append(UInt8(remaining & 127) | 128)
        remaining >>= 7
    data.append(UInt8(remaining))


def _packed(count: Int, invalid: Int = -1) -> List[UInt8]:
    var data = List[UInt8]()
    if count == 0:
        return data^
    var groups = (count + 7) // 8
    _varint(data, groups * 2 + 1)
    var start = len(data)
    data.extend(List[UInt8](length=groups * 2, fill=0))
    for i in range(groups * 8):
        var value = UInt8(i % 2)
        if i >= count or i == invalid:
            value = 3  # Legal unused padding, invalid actual dictionary ID.
        data[start + i // 4] |= value << UInt8((i % 4) * 2)
    return data^


def _case[dtype: DType](
    mask: List[UInt8], mode: Int = 0, invalid: Int = -1, reject: Bool = False,
) raises:
    var count = len(mask)
    var present = 0
    for valid in mask:
        present += Int(valid)
    var data = List[UInt8]()
    var groups = (count + 7) // 8
    if count != 0:
        _varint(data, groups * 2 + 1)
        var start = len(data)
        data.extend(List[UInt8](length=groups, fill=0))
        for i in range(count):
            data[start + i // 8] |= mask[i] << UInt8(i % 8)
    var levels = len(data)
    data.append(2)
    if mode == 1 and present > 0:
        _varint(data, present * 2)
        data.append(UInt8(3 if invalid >= 0 else 1))
    elif (mode == 5 or mode == 6) and present > 129:
        data.extend(_packed(64))
        _varint(data, 65 * 2)
        data.append(1)
        data.extend(_packed(present - 129))
    elif mode == 2 and present >= 129:
        _varint(data, 129 * 2)
        data.append(1)
        data.extend(_packed(present - 129, invalid))
    else:
        data.extend(_packed(present, invalid))
    if mode == 3:
        data.append(0)  # Trailing stream, including zero-present stream.
    elif mode == 4 or mode == 6:
        _ = data.pop()  # Truncated payload (or width on all-null page).
    var h = PageHeader()
    h.page_type = 3
    h.encoding = 8
    h.num_values = count
    h.num_nulls = count - present
    h.definition_levels_byte_length = levels
    h.repetition_levels_byte_length = 0
    var dictionary: List[Scalar[dtype]] = [Scalar[dtype](3), Scalar[dtype](7)]
    comptime if dtype == DType.float32:
        dictionary = [bitcast[dtype](UInt32(0x80000000)), bitcast[dtype](UInt32(0x7F812345))]
    elif dtype == DType.float64:
        dictionary = [bitcast[dtype](UInt64(0x8000000000000000)), bitcast[dtype](UInt64(0x7FF8123456789ABC))]
    var values = empty[dtype]([count + 6])
    var pointer = values.unsafe_ptr()
    for i in range(count + 6):
        pointer[unsafe_offset=i] = Scalar[dtype](19)
    var bitmap = List[UInt8](length=(count + 13) // 8, fill=0)
    if reject:
        with assert_raises():
            _ = _decode_numeric_page[dtype](data, h, True, values, bitmap, 3, dictionary, True)
    else:
        assert_equal(_decode_numeric_page[dtype](data, h, True, values, bitmap, 3, dictionary, True), count - present)
        var consumed = 0
        for i in range(count):
            var expected = Scalar[dtype](0)
            if mask[i]:
                var index = consumed % 2
                if mode == 1 or (mode == 2 and present >= 129 and consumed < 129):
                    index = 1
                elif mode == 2 and present >= 129:
                    index = (consumed - 129) % 2
                if mode == 5 and present > 129:
                    if consumed >= 64 and consumed < 129:
                        index = 1
                    elif consumed >= 129:
                        index = (consumed - 129) % 2
                expected = dictionary[index]
                consumed += 1
            _assert_bits[dtype](pointer[unsafe_offset=i + 3], expected)
            assert_equal(Bool(bitmap[(i + 3) // 8] & (UInt8(1) << UInt8((i + 3) % 8))), Bool(mask[i]))
        assert_equal(consumed, present)
    # Partial private writes are permitted on failure; surrounding slots aren't.
    for i in range(3):
        _assert_bits[dtype](pointer[unsafe_offset=i], Scalar[dtype](19))
        _assert_bits[dtype](pointer[unsafe_offset=count + 3 + i], Scalar[dtype](19))


def _typed[dtype: DType]() raises:
    for count in range(130):
        var mask = List[UInt8](length=count * 2 + 1, fill=0)
        for i in range(count):
            mask[i * 2 + 1] = 1
        _case[dtype](mask)
        _case[dtype](mask, 1)
        if count > 0:
            _case[dtype](mask, invalid=count - 1, reject=True)
        _case[dtype](mask, 3, reject=True)
        _case[dtype](mask, 4, reject=True)
    for density in range(5):
        var percent = 0 if density == 0 else 1 if density == 1 else 50 if density == 2 else 99 if density == 3 else 100
        for clustered in range(2):
            var mask = List[UInt8](length=1027, fill=0)
            for i in range(1027):
                var is_null = i * 37 % 100 < percent
                if clustered:
                    is_null = i >= (1027 - 1027 * percent // 100) // 2 and i < (1027 + 1027 * percent // 100) // 2
                mask[i] = UInt8(not is_null)
            _case[dtype](mask)
            _case[dtype](mask, 1)
            _case[dtype](mask, 2)
    var mask = List[UInt8](length=301, fill=1)
    mask[0] = 0
    mask[64] = 0
    mask[129] = 0
    var boundaries: List[Int] = [0, 7, 8, 63, 64, 65, 127, 128, 129, 255, 256]
    for index in boundaries:
        _case[dtype](mask, invalid=index, reject=True)
    _case[dtype](mask, 1, invalid=0, reject=True)
    _case[dtype](mask, 2, invalid=64, reject=True)
    # A packed batch, repeated run, then packed tail. Truncating that tail
    # fails after earlier private writes, rather than during the first run.
    _case[dtype](mask, 5)
    _case[dtype](mask, 6, reject=True)
    var zero = List[UInt8]()
    _case[dtype](zero)
    _case[dtype](zero, 3, reject=True)


def test_nullable_numeric_types() raises:
    comptime types = (DType.int8, DType.uint8, DType.int16, DType.uint16, DType.int32, DType.uint32, DType.int64, DType.uint64, DType.float32, DType.float64)
    comptime for i in range(len(types)):
        _typed[types[i]]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
