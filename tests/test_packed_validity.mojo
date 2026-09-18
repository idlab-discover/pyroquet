"""Exact bounded flat-level regressions; checks stay active with ASSERT=none."""
from std.testing import TestSuite
from pyroquet.format.flat_pages import _definition_levels, _flat_page_values
from pyroquet.format.pages import PageHeader


def _check(condition: Bool, message: String) raises:
    if not condition:
        raise Error(message)


def _varint(mut data: List[UInt8], value: Int):
    var left = value
    while left >= 128:
        data.append(UInt8(left & 127) | 128)
        left >>= 7
    data.append(UInt8(left))


def _packed(mut data: List[UInt8], values: List[UInt8]):
    var groups = (len(values) + 7) // 8
    _varint(data, groups * 2 + 1)
    for group in range(groups):
        # Nonzero padding must not contribute to the result or present count.
        var byte = UInt8(255)
        for bit in range(8):
            var row = group * 8 + bit
            if row < len(values) and values[row] == 0:
                byte &= ~(UInt8(1) << UInt8(bit))
        data.append(byte)


def _pattern(count: Int, kind: Int) -> List[UInt8]:
    var values = List[UInt8](capacity=count)
    var random = UInt32(0xD31B2497)
    for row in range(count):
        random ^= random << 13
        random ^= random >> 17
        random ^= random << 5
        var bit = UInt8(0)
        if kind == 1:
            bit = 1
        elif kind == 2:
            bit = UInt8(row % 2)
        elif kind == 3:
            bit = UInt8(random & 1)
        values.append(bit)
    return values^


def _reference(
    mut bitmap: List[UInt8], output: Int, values: List[UInt8]
) -> Int:
    # Independent scalar oracle: no shared framing, copy helper or popcount.
    var count = 0
    for row in range(len(values)):
        if values[row] != 0:
            var index = output + row
            bitmap[index // 8] |= UInt8(1) << UInt8(index % 8)
            count += 1
    return count


def _guarded(output: Int, count: Int, suffix: Int) -> List[UInt8]:
    var bitmap = List[UInt8](length=(output + count + 7) // 8 + suffix, fill=0)
    # Destination belongs to a zero-initialized column. Seed only neighbors,
    # including unused final-byte bits; decoding must preserve those exactly.
    for bit in range(len(bitmap) * 8):
        if bit < output or bit >= output + count:
            if bit % 3 != 0:
                bitmap[bit // 8] |= UInt8(1) << UInt8(bit % 8)
    return bitmap^


def _compare(
    data: List[UInt8],
    start: Int,
    end: Int,
    values: List[UInt8],
    output: Int,
    suffix: Int,
) raises:
    var actual = _guarded(output, len(values), suffix)
    var expected = actual.copy()
    var wanted = _reference(expected, output, values)
    var present = _definition_levels(
        data, start, end, len(values), actual, output
    )
    _check(present == wanted, "Logical present count differs")
    _check(actual == expected, "Validity or neighboring bits differ")


def test_all_alignments_lengths_patterns_and_logical_padding() raises:
    var lengths: List[Int] = [
        1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 55, 56, 57, 63, 64, 65,
        71, 72, 73, 127, 128, 129, 255, 256, 257, 4095, 4096, 4097,
        65535, 65536, 65537,
    ]
    for alignment in range(8):
        for kind in range(4):
            for count in lengths:
                var values = _pattern(count, kind)
                var data = List[UInt8](length=alignment, fill=0xCC)
                _packed(data, values)
                # No source suffix; include exact-size destination allocation.
                _compare(data, alignment, len(data), values, 8 + alignment, 0)
            for padding in range(8):
                var values = _pattern(80 - padding, kind)
                var data: List[UInt8] = [0xCC]
                _packed(data, values)
                var end = len(data)
                data.append(0xCC)
                _compare(data, 1, end, values, alignment, 2)


def test_mixed_runs_shift_packed_destinations() raises:
    for alignment in range(8):
        for prefix in range(1, 9):
            for padding in range(8):
                var data = List[UInt8]()
                var values = List[UInt8]()
                _varint(data, prefix * 2)
                data.append(1)
                for _ in range(prefix):
                    values.append(1)
                var first = _pattern(80, 3)
                _packed(data, first)
                values.extend(first^)
                _varint(data, 14)
                data.append(0)
                for _ in range(7):
                    values.append(0)
                var last = _pattern(72 - padding, 2)
                _packed(data, last)
                values.extend(last^)
                _compare(data, 0, len(data), values, alignment, 1)


def _header(kind: Int, rows: Int, nulls: Int, levels: Int) -> PageHeader:
    var h = PageHeader()
    h.page_type = kind
    h.num_values = rows
    h.num_rows = rows
    h.num_nulls = nulls
    h.definition_levels_byte_length = levels
    h.repetition_levels_byte_length = 0
    h.definition_level_encoding = 3
    return h


def test_consecutive_v1_v2_pages_sharing_byte_and_value_boundary() raises:
    for alignment in range(8):
        var actual = _guarded(alignment, 29, 1)
        var expected = actual.copy()
        var output = alignment
        for page in range(3):
            var count = 5 if page == 0 else (9 if page == 1 else 15)
            var values = _pattern(count, page + 1)
            var wanted = _reference(expected, output, values)
            var levels = List[UInt8]()
            _packed(levels, values)
            var kind = 0 if page % 2 == 0 else 3
            var data = List[UInt8]()
            if kind == 0:
                for bit in range(4):
                    data.append(UInt8((len(levels) >> (bit * 8)) & 255))
            data.extend(levels.copy())
            var value_start = len(data)
            # Value bytes would be invalid level framing if over-consumed.
            data.append(0x80)
            data.append(0xFF)
            var h = _header(kind, count, count - wanted, len(levels))
            var result = _flat_page_values(data, h, True, actual, output)
            _check(result[0] == value_start, "Value payload offset changed")
            _check(result[1] == wanted, "Page present count differs")
            _check(actual == expected, "Consecutive page validity differs")
            output += count


def _reject(data: List[UInt8], count: Int) raises:
    var bitmap = List[UInt8](length=4, fill=0)
    var rejected = False
    try:
        _ = _definition_levels(data, 0, len(data), count, bitmap, 0)
    except:
        rejected = True
    _check(rejected, "Malformed level run accepted")


def test_malformed_runs_and_empty_streams() raises:
    _compare(List[UInt8](), 0, 0, List[UInt8](), 3, 1)
    _reject([128], 1)
    _reject([128, 128, 128, 128, 128], 1)
    _reject([255, 255, 255, 255, 16], 1)
    _reject([255, 255, 255, 255, 15], 1)
    _reject([254, 255, 255, 255, 15], 1)
    _reject([0], 1)
    _reject([1], 1)
    _reject([2], 1)
    _reject([3], 1)
    _reject([5, 255], 9)
    _reject([4, 1], 1)
    _reject([5, 255, 255], 8)
    _reject([3, 255, 2, 1], 1)
    _reject([2, 2], 1)
    _reject([2, 0, 0], 1)
    _reject([0], 0)


def _reject_page(
    data: List[UInt8],
    h: PageHeader,
    output: Int = 0,
    nullable: Bool = True,
) raises:
    var bitmap = List[UInt8](length=2, fill=0)
    var rejected = False
    try:
        _ = _flat_page_values(data, h, nullable, bitmap, output)
    except:
        rejected = True
    _check(rejected, "Malformed page framing accepted")


def test_v1_v2_bounds_encoding_and_count_rejections() raises:
    _reject_page([3, 255], _header(3, 5, 1, 2))
    _reject_page([3, 0], _header(3, 5, 4, 2))
    _reject_page([3, 255], _header(3, 5, 0, 3))
    _reject_page([3, 255], _header(3, 5, 0, -1))
    _reject_page([3, 255], _header(3, 5, 0, 2), 12)
    _reject_page([3, 255], _header(3, 5, 0, 2), -1)
    _reject_page([3, 255], _header(3, -1, 0, 2))
    _reject_page([3, 255], _header(3, 5, 0, 2), 0, False)
    _reject_page([2, 0, 0], _header(0, 5, 0, 2))
    _reject_page([3, 0, 0, 0, 3, 255], _header(0, 5, 0, 2))
    var h = _header(3, 5, 0, 2)
    h.repetition_levels_byte_length = 1
    _reject_page([3, 255], h)
    h = _header(0, 5, 0, 2)
    h.definition_level_encoding = 4
    _reject_page([2, 0, 0, 0, 3, 255], h)
    _reject_page([3, 255], _header(2, 5, 0, 2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
