"""Wire-level hybrid regression tests; no external codec or Python runtime."""
from std.testing import assert_equal, assert_raises, TestSuite
from pyroquet.format.hybrid import _HybridDecoder


def _decode(
    data: List[UInt8], width: Int, count: Int, batched: Bool = False
) raises:
    var decoder = _HybridDecoder(0, len(data), width, count)
    if batched:
        var scratch: List[UInt32] = [0, 0, 0]
        var left = count
        while left > 0:
            var batch = decoder.next_batch(data, Span(scratch), left)
            left -= batch[0]
    else:
        for _ in range(count):
            _ = decoder.next(data)
    decoder.finish()


def test_spec_packed_example_and_final_padding() raises:
    var data: List[UInt8] = [3, 0x88, 0xC6, 0xFA]
    for count in range(1, 9):
        var decoder = _HybridDecoder(0, len(data), 3, count)
        for i in range(count):
            assert_equal(decoder.next(data), UInt32(i))
        decoder.finish()


def test_mixed_runs_and_substream() raises:
    var data: List[UInt8] = [99, 6, 5, 3, 0x88, 0xC6, 0xFA, 4, 2, 99]
    var decoder = _HybridDecoder(1, 9, 3, 13)
    for _ in range(3):
        assert_equal(decoder.next(data), UInt32(5))
    for i in range(8):
        assert_equal(decoder.next(data), UInt32(i))
    for _ in range(2):
        assert_equal(decoder.next(data), UInt32(2))
    decoder.finish()
    with assert_raises():
        _ = decoder.next(data)


def test_all_widths_cross_bytes() raises:
    for width in range(33):
        var data: List[UInt8] = [5]  # Two packed groups.
        for _ in range(width * 2):
            data.append(0)
        var values = List[UInt32]()
        for i in range(16):
            var value = UInt32(i) * UInt32(0x13579BDF)
            if width < 32:
                value &= (UInt32(1) << UInt32(width)) - 1
            values.append(value)
            for bit in range(width):
                var pos = i * width + bit
                data[1 + pos // 8] |= UInt8(
                    (value >> UInt32(bit)) & 1
                ) << UInt8(pos % 8)
        # Exercise every legal final-group padding length, including nonzero
        # unused values, at every width. This catches accumulator tail reads.
        for count in range(9, 17):
            var decoder = _HybridDecoder(0, len(data), width, count)
            for i in range(count):
                assert_equal(decoder.next(data), values[i])
            decoder.finish()
        data.append(3)
        for i in range(width):
            data.append(data[1 + i])
        var continued = _HybridDecoder(0, len(data), width, 24)
        for i in range(24):
            assert_equal(continued.next(data), values[i % 16])
        continued.finish()


def test_zero_width_and_empty_streams() raises:
    var rle: List[UInt8] = [10]
    var packed: List[UInt8] = [3]
    _decode(rle, 0, 5)
    _decode(packed, 0, 1)
    var empty = List[UInt8]()
    _decode(empty, 0, 0)
    _decode(empty, 32, 0)
    with assert_raises():
        _decode(rle, 0, 0)
    with assert_raises():
        _decode(empty, 0, 1)


def test_rle_width_32_and_multibyte_header() raises:
    var data: List[UInt8] = [0x80, 2, 0xFF, 0xFF, 0xFF, 0xFF]
    var decoder = _HybridDecoder(0, len(data), 32, 128)
    for _ in range(128):
        assert_equal(decoder.next(data), UInt32(0xFFFFFFFF))
    decoder.finish()


def test_malformed_runs() raises:
    var truncated_header: List[UInt8] = [128]
    var overflowing_header: List[UInt8] = [255, 255, 255, 255, 16]
    var zero_rle: List[UInt8] = [0]
    var zero_packed: List[UInt8] = [1]
    var short_rle: List[UInt8] = [2]
    var short_packed: List[UInt8] = [3, 0]
    var long_rle: List[UInt8] = [4, 0]
    var long_packed: List[UInt8] = [5, 0, 0]
    var padding_then_run: List[UInt8] = [3, 0, 2, 0]
    var high_rle_bits: List[UInt8] = [2, 2]
    var trailing: List[UInt8] = [2, 0, 0]
    var enormous_rle: List[UInt8] = [254, 255, 255, 255, 15]
    var enormous_packed: List[UInt8] = [255, 255, 255, 255, 15]
    for batched in range(2):
        with assert_raises():
            _decode(truncated_header, 1, 1, Bool(batched))
        with assert_raises():
            _decode(overflowing_header, 1, 1, Bool(batched))
        with assert_raises():
            _decode(zero_rle, 1, 1, Bool(batched))
        with assert_raises():
            _decode(zero_packed, 1, 1, Bool(batched))
        with assert_raises():
            _decode(short_rle, 1, 1, Bool(batched))
        with assert_raises():
            _decode(short_packed, 2, 8, Bool(batched))
        with assert_raises():
            _decode(long_rle, 1, 1, Bool(batched))
        with assert_raises():
            _decode(long_packed, 1, 1, Bool(batched))
        with assert_raises():
            _decode(padding_then_run, 1, 1, Bool(batched))
        with assert_raises():
            _decode(high_rle_bits, 1, 1, Bool(batched))
        with assert_raises():
            _decode(trailing, 1, 1, Bool(batched))
        with assert_raises():
            _decode(enormous_rle, 0, 1, Bool(batched))
        with assert_raises():
            _decode(enormous_packed, 0, 2147483647, Bool(batched))


def test_invalid_bounds_and_unfinished() raises:
    with assert_raises():
        var decoder = _HybridDecoder(-1, 0, 0, 0)
    with assert_raises():
        var decoder = _HybridDecoder(2, 1, 0, 0)
    with assert_raises():
        var decoder = _HybridDecoder(0, 0, 33, 0)
    with assert_raises():
        var decoder = _HybridDecoder(0, 0, -1, 0)
    with assert_raises():
        var decoder = _HybridDecoder(0, 0, 0, -1)
    var empty = List[UInt8]()
    with assert_raises():
        var decoder = _HybridDecoder(0, 1, 1, 1)
        _ = decoder.next(empty)
    with assert_raises():
        var decoder = _HybridDecoder(0, 0, 1, 1)
        decoder.finish()


def test_batches_all_widths_and_partial_scalar_consumption() raises:
    for width in range(33):
        # Eighteen complete groups exercise word refills and 64-ID boundaries.
        var data: List[UInt8] = [37]
        for _ in range(width * 18):
            data.append(0)
        var expected = List[UInt32]()
        for i in range(144):
            var value = UInt32(i) * UInt32(0x13579BDF)
            if width < 32:
                value &= (UInt32(1) << UInt32(width)) - 1
            expected.append(value)
            for bit in range(width):
                var pos = i * width + bit
                data[1 + pos // 8] |= UInt8(
                    (value >> UInt32(bit)) & 1
                ) << UInt8(pos % 8)
        var scratch = List[UInt32]()
        for _ in range(96):
            scratch.append(0xFFFFFFFF)
        for count in range(137, 145):
            for limit in range(63, 66):
                var decoder = _HybridDecoder(0, len(data), width, count)
                # Begin batches at a non-byte-aligned position for odd widths.
                assert_equal(decoder.next(data), expected[0])
                var consumed = 1
                while consumed < count:
                    var batch = decoder.next_batch(data, Span(scratch), limit)
                    assert_equal(batch[1], False)
                    assert_equal(
                        batch[0], min(64, min(limit, count - consumed))
                    )
                    for i in range(batch[0]):
                        assert_equal(scratch[i], expected[consumed + i])
                    # Capacity above the documented bound is untouched.
                    assert_equal(scratch[64], UInt32(0xFFFFFFFF))
                    consumed += batch[0]
                    if consumed < count:
                        assert_equal(decoder.next(data), expected[consumed])
                        consumed += 1
                decoder.finish()


def test_batches_repeated_mixed_runs_and_destination_capacity() raises:
    var data: List[UInt8] = [99, 0x80, 2, 5, 3, 0x88, 0xC6, 0xFA, 4, 2, 99]
    var decoder = _HybridDecoder(1, 10, 3, 138)
    var scratch: List[UInt32] = [0, 0, 0]
    var batch = decoder.next_batch(data, Span(scratch), 65)
    assert_equal(batch[0], 65)
    assert_equal(batch[1], True)
    assert_equal(scratch[0], UInt32(5))
    assert_equal(decoder.next(data), UInt32(5))
    batch = decoder.next_batch(data, Span(scratch), 1000)
    assert_equal(batch[0], 62)
    assert_equal(batch[1], True)
    for base in range(2):
        batch = decoder.next_batch(data, Span(scratch), 1000)
        assert_equal(batch[0], 3)
        assert_equal(batch[1], False)
        for i in range(3):
            assert_equal(scratch[i], UInt32(base * 3 + i))
    assert_equal(decoder.next(data), UInt32(6))
    batch = decoder.next_batch(data, Span(scratch), 1000)
    assert_equal(batch[0], 1)
    assert_equal(batch[1], False)
    assert_equal(scratch[0], UInt32(7))
    batch = decoder.next_batch(data, Span(scratch), 1000)
    assert_equal(batch[0], 2)
    assert_equal(batch[1], True)
    assert_equal(scratch[0], UInt32(2))
    decoder.finish()
    with assert_raises():
        _ = decoder.next_batch(data, Span(scratch), 1)


def test_batch_capacity_alignment_padding_and_destination_guards() raises:
    var boundaries: List[Int] = [1, 7, 8, 9, 63, 64, 65]
    for width in range(33):
        var expected = List[UInt32]()
        var mask = UInt32(0xFFFFFFFF)
        if width < 32:
            mask = (UInt32(1) << UInt32(width)) - 1
        for i in range(144):
            # Include the largest representable value, including UInt32.MAX.
            expected.append(
                mask if i % 7 == 0 else UInt32(i) * UInt32(0x13579BDF) & mask
            )
        for padding in range(8):
            for boundary in range(len(boundaries)):
                var capacity = boundaries[boundary]
                var limit = boundaries[(boundary + padding) % len(boundaries)]
                var offset = 1 + (boundary + padding + width) % 9
                var data = List[UInt8](length=offset, fill=0xFF)
                data.append(37)  # Eighteen packed groups.
                for _ in range(width * 18):
                    data.append(0)
                for i in range(144):
                    for bit in range(width):
                        var pos = i * width + bit
                        data[offset + 1 + pos // 8] |= UInt8(
                            (expected[i] >> UInt32(bit)) & 1
                        ) << UInt8(pos % 8)
                # The source ends at the payload: a short last load cannot
                # rely on another run or an accessible suffix allocation.
                var count = 144 - padding
                var decoder = _HybridDecoder(offset, len(data), width, count)
                var scratch = List[UInt32](length=capacity + 2, fill=0xA5A5A5A5)
                var consumed = 0
                for _ in range(padding):
                    assert_equal(decoder.next(data), expected[consumed])
                    consumed += 1
                while consumed < count:
                    for i in range(len(scratch)):
                        scratch[i] = 0xA5A5A5A5
                    var batch = decoder.next_batch(
                        data, Span(scratch)[1 : capacity + 1], limit
                    )
                    assert_equal(batch[1], False)
                    assert_equal(
                        batch[0],
                        min(count - consumed, min(64, min(capacity, limit))),
                    )
                    assert_equal(scratch[0], UInt32(0xA5A5A5A5))
                    for i in range(batch[0]):
                        assert_equal(scratch[i + 1], expected[consumed + i])
                    for i in range(batch[0] + 1, len(scratch)):
                        assert_equal(scratch[i], UInt32(0xA5A5A5A5))
                    consumed += batch[0]
                    if consumed < count:
                        assert_equal(decoder.next(data), expected[consumed])
                        consumed += 1
                decoder.finish()


def test_all_widths_packed_batches_across_run_transitions() raises:
    for width in range(33):
        var mask = UInt32(0xFFFFFFFF)
        if width < 32:
            mask = (UInt32(1) << UInt32(width)) - 1
        for offset in range(1, 10):
            var data = List[UInt8](length=offset, fill=0xFF)
            var expected = List[UInt32]()
            # Two full-sized packed runs separated by RLE ensure speculative
            # packed reads cannot consume framing or reuse stale reservoir bits.
            for run in range(2):
                data.append(6)
                for _ in range((width + 7) // 8):
                    data.append(0)
                for _ in range(3):
                    expected.append(0)
                data.append(21)
                for _ in range(width * 10):
                    data.append(0xFF)
                var present = 80 if run == 0 else 80 - (offset - 1) % 8
                for _ in range(present):
                    expected.append(mask)
            var decoder = _HybridDecoder(
                offset, len(data), width, len(expected)
            )
            var scratch = List[UInt32](length=65, fill=0xA5A5A5A5)
            var consumed = 0
            while consumed < len(expected):
                var batch = decoder.next_batch(data, Span(scratch)[:64], 65)
                for i in range(batch[0]):
                    assert_equal(
                        scratch[0 if batch[1] else i], expected[consumed + i]
                    )
                assert_equal(scratch[64], UInt32(0xA5A5A5A5))
                consumed += batch[0]
                if consumed < len(expected):
                    assert_equal(decoder.next(data), expected[consumed])
                    consumed += 1
            decoder.finish()


def test_invalid_batch_arguments_and_short_buffer() raises:
    var data: List[UInt8] = [2, 1]
    var decoder = _HybridDecoder(0, len(data), 1, 1)
    var scratch: List[UInt32] = [0]
    var empty = List[UInt32]()
    with assert_raises():
        _ = decoder.next_batch(data, Span(empty), 1)
    with assert_raises():
        _ = decoder.next_batch(data, Span(scratch), 0)
    with assert_raises():
        _ = decoder.next_batch(data, Span(scratch), -1)
    # Argument errors did not consume stream state.
    assert_equal(decoder.next_batch(data, Span(scratch), 1)[0], 1)
    assert_equal(scratch[0], UInt32(1))
    decoder.finish()
    decoder = _HybridDecoder(0, len(data) + 1, 1, 1)
    with assert_raises():
        _ = decoder.next_batch(data, Span(scratch), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
