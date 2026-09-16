"""Raw Snappy page contracts; checks remain active with ASSERT=none."""
from std.testing import TestSuite
from pyroquet.format import PageHeader
from pyroquet.format.flat_pages import _page_body


def _header(
    kind: Int, stored: Int, decoded: Int, levels: Int = 0
) -> PageHeader:
    var h = PageHeader()
    h.page_type = kind
    h.compressed_page_size = stored
    h.uncompressed_page_size = decoded
    h.repetition_levels_byte_length = 0
    h.definition_levels_byte_length = levels
    return h


def _same(actual: List[UInt8], expected: List[UInt8]) raises:
    if actual != expected:
        raise Error("Decoded page bytes differ")


def _reject(var data: List[UInt8], h: PageHeader, codec: Int = 1) raises:
    var rejected = False
    try:
        _ = _page_body(data^, h, codec)
    except:
        rejected = True
    if not rejected:
        raise Error("Malformed page unexpectedly accepted")


def test_raw_v1_and_dictionary_complete_bodies() raises:
    # V1 level framing belongs inside the compressed body, as do dictionary
    # values. Neither body uses a framed Snappy stream or a V2 prefix.
    var wanted: List[UInt8] = [2, 0, 0, 0, 6, 1, 42, 0, 0, 0]
    for kind in [0, 2]:
        var raw: List[UInt8] = [10, 36]
        raw.extend(wanted.copy())
        _same(_page_body(raw^, _header(kind, 12, 10), 1), wanted)
        _same(_page_body([0], _header(kind, 1, 0), 1), List[UInt8]())
        _reject(List[UInt8](), _header(kind, 0, 0))


def test_v2_preserves_levels_and_bypasses_uncompressed_values() raises:
    var wanted: List[UInt8] = [3, 5, 42, 0, 0, 0]
    _same(
        _page_body([3, 5, 4, 12, 42, 0, 0, 0], _header(3, 8, 6, 2), 1),
        wanted,
    )
    var h = _header(3, 6, 6, 2)
    h.is_compressed = False
    # Raw values are deliberately not a valid Snappy block.
    _same(_page_body(wanted.copy(), h, 1), wanted)
    h.is_compressed = True
    _reject(wanted.copy(), h)
    _same(_page_body([6, 0, 0], _header(3, 3, 2, 2), 1), [6, 0])
    _same(_page_body([0], _header(3, 1, 0), 1), List[UInt8]())
    _reject([6, 0], _header(3, 2, 2, 2))
    _reject([6, 0, 1], _header(3, 3, 2, 2))


def test_page_lengths_and_level_bounds() raises:
    _reject([0], _header(0, 2, 0))
    _reject([0], _header(0, 1, 1))
    _reject([0], _header(0, 1, -1))
    _reject([0], _header(0, 1, 0), 2)
    _reject([0], _header(3, 1, 0, 1))
    _reject([0], _header(3, 1, 2, 2))
    _reject([0], _header(3, 1, 0, -1))
    var h = _header(3, 1, 0)
    h.repetition_levels_byte_length = 1
    _reject([0], h)
    h = _header(3, 1, 0)
    h.is_compressed = False
    _reject([0], h)
    _reject([0], _header(0, 1, 0), 0)


def test_framed_snappy_is_not_a_page_payload() raises:
    # Standard framed-stream identifier must never be stripped implicitly.
    var framed: List[UInt8] = [255, 6, 0, 0, 115, 78, 97, 80, 112, 89]
    for kind in [0, 2, 3]:
        _reject(framed.copy(), _header(kind, len(framed), 0))


def test_truncated_literals_and_copies_through_page_seam() raises:
    for width in range(1, 5):
        for available in range(width):
            var raw: List[UInt8] = [1, UInt8((59 + width) << 2)]
            for _ in range(available):
                raw.append(0)
            _reject(raw.copy(), _header(0, len(raw), 1))
            var suffix: List[UInt8] = [2, 1]
            suffix.extend(raw^)
            _reject(suffix.copy(), _header(3, len(suffix), 3, 2))
    for kind in [1, 2, 3]:
        var width = 1 if kind == 1 else (2 if kind == 2 else 4)
        for available in range(width):
            var raw: List[UInt8] = [
                5,
                0,
                42,
                UInt8(1 if kind == 1 else 12 | kind),
            ]
            for i in range(available):
                raw.append(UInt8(1 if i == 0 else 0))
            _reject(raw.copy(), _header(2, len(raw), 5))
    _reject([2, 4, 42], _header(0, 3, 2))
    _reject([1, 0], _header(0, 2, 1))


def test_invalid_offsets_and_output_totals() raises:
    for kind in [1, 2, 3]:
        var width = 1 if kind == 1 else (2 if kind == 2 else 4)
        for offset in [0, 2]:
            var raw: List[UInt8] = [
                5,
                0,
                42,
                UInt8(1 if kind == 1 else 12 | kind),
            ]
            raw.append(UInt8(offset))
            for _ in range(width - 1):
                raw.append(0)
            _reject(raw.copy(), _header(0, len(raw), 5))
    _reject([4, 0, 42, 14, 1, 0], _header(0, 6, 4))  # Copy overflow.
    _reject([6, 0, 42, 14, 1, 0], _header(0, 6, 6))  # Underflow.
    _reject([0, 0, 42], _header(0, 3, 0))  # Trailing literal.
    _reject([1, 0, 42, 2, 1, 0], _header(0, 6, 1))  # Trailing copy.


def test_copy_forms_all_small_offsets_and_lengths() raises:
    # Independent wire construction covers growing overlap, exact end reads,
    # SIMD tails and decoder List growth through the real page interface.
    for kind in [1, 2, 3]:
        for offset in range(1, 34):
            for count in range(1, 65):
                if kind == 1 and (count < 4 or count > 11):
                    continue
                var raw: List[UInt8] = [
                    UInt8(offset + count),
                    UInt8((offset - 1) << 2),
                ]
                var wanted = List[UInt8]()
                for i in range(offset):
                    raw.append(UInt8(i))
                    wanted.append(UInt8(i))
                var tag = ((count - 1) << 2) | kind
                if kind == 1:
                    tag = ((count - 4) << 2) | 1
                raw.append(UInt8(tag))
                raw.append(UInt8(offset))
                var width = 1 if kind == 1 else (2 if kind == 2 else 4)
                for _ in range(width - 1):
                    raw.append(0)
                for i in range(count):
                    wanted.append(UInt8(i % offset))
                _same(
                    _page_body(
                        raw.copy(), _header(0, len(raw), len(wanted)), 1
                    ),
                    wanted,
                )
                var suffix: List[UInt8] = [3, 5]
                suffix.extend(raw^)
                var with_levels: List[UInt8] = [3, 5]
                with_levels.extend(wanted^)
                _same(
                    _page_body(
                        suffix.copy(),
                        _header(3, len(suffix), len(with_levels), 2),
                        1,
                    ),
                    with_levels,
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
