"""Bounded flat page framing shared by numeric and Boolean/binary readers.

Owns decompression, V1/V2 level framing and exact null-count validation.
Typed materializers own values and dictionaries; no storage dependency here.
"""
from .pages import PageHeader
from std.bit import pop_count
from ..compression import decompress, validate_codec


def _u32(bytes: List[UInt8], offset: Int, end: Int) raises -> UInt32:
    if offset < 0 or offset > end or end > len(bytes) or end - offset < 4:
        raise Error("Truncated UInt32 payload")
    var value = UInt32(0)
    for j in range(4):
        value |= UInt32(bytes[offset + j]) << UInt32(j * 8)
    return value


def _set_valid(mut bitmap: List[UInt8], index: Int):
    bitmap[index // 8] |= UInt8(1) << UInt8(index % 8)


def _set_valid_run(mut bitmap: List[UInt8], first: Int, count: Int):
    """Set a validated present run, preserving neighboring page bits."""
    var pos = first
    var stop = first + count
    while pos < stop and pos % 8 != 0:
        _set_valid(bitmap, pos)
        pos += 1
    while stop - pos >= 8:
        bitmap[pos // 8] = 255
        pos += 8
    while pos < stop:
        _set_valid(bitmap, pos)
        pos += 1


def _definition_levels(
    bytes: List[UInt8],
    start: Int,
    end: Int,
    count: Int,
    mut bitmap: List[UInt8],
    output: Int,
) raises -> Int:
    """Decode one-bit RLE/bit-packed hybrid directly into final validity."""
    var pos = start
    var written = 0
    var present = 0
    while written < count:
        var header = UInt32(0)
        var terminated = False
        for j in range(5):
            if pos >= end:
                raise Error("Truncated definition-level run")
            var byte = bytes[pos]
            pos += 1
            if j == 4 and byte > 15:
                raise Error("Definition-level varint overflow")
            header |= UInt32(byte & 127) << UInt32(j * 7)
            if (byte & 128) == 0:
                terminated = True
                break
        if not terminated:
            raise Error("Definition-level varint overflow")
        var run = Int(header >> 1)
        if run == 0:
            raise Error("Zero-length definition-level run")
        if (header & 1) == 0:
            if run > count - written or pos >= end:
                raise Error("Definition-level RLE run exceeds page")
            var value = bytes[pos]
            pos += 1
            if value > 1:
                raise Error("Invalid flat definition level")
            if value == 1:
                _set_valid_run(bitmap, output + written, run)
                present += run
            written += run
        else:
            # Each group contains eight one-bit levels in one byte.
            if run > 2147483647 // 8 or run > end - pos:
                raise Error("Truncated or oversized bit-packed levels")
            var total = run * 8
            var used = total
            if used > count - written:
                used = count - written
                if total - used > 7:
                    raise Error("Excess bit-packed definition levels")
            # Both wire levels and validity are LSB-first. Framing above
            # bounds all run bytes; ceil(used / 8) <= run, so every load is
            # inside the payload, with no padded-input overread. The caller
            # bounds output + count by bitmap capacity and initializes the
            # target bits to zero. OR preserves neighboring page/group bits.
            var shift = (output + written) % 8
            var dest = (output + written) // 8
            var i = 0
            while i < used:
                var bits = bytes[pos + i // 8]
                var take = min(8, used - i)
                # Widen the mask so even take == 8 shifts by less than the
                # operand width. Only logical rows enter the population count.
                bits &= UInt8((UInt16(1) << UInt16(take)) - 1)
                present += Int(pop_count(bits))
                # shift is 0..7. A second byte exists iff logical bits cross
                # its boundary; then 8-shift is 1..7, never a width-sized shift.
                bitmap[dest] |= bits << UInt8(shift)
                if take > 8 - shift:
                    bitmap[dest + 1] |= bits >> UInt8(8 - shift)
                dest += 1
                i += take
            pos += run
            written += used
    if pos != end:
        raise Error("Trailing definition-level bytes")
    return present


def _flat_page_values(
    data: List[UInt8],
    h: PageHeader,
    nullable: Bool,
    mut validity: List[UInt8],
    output: Int,
) raises -> Tuple[Int, Int]:
    """Validate flat V1/V2 levels into final validity; return value start/count.
    """
    if (
        h.num_values < 0
        or output < 0
        or (nullable and output + h.num_values > len(validity) * 8)
    ):
        raise Error("Definition levels exceed output validity")
    var start = 0
    var end = 0
    if h.page_type == 0:
        if nullable:
            if h.definition_level_encoding != 3:
                raise Error("Only hybrid definition levels are supported")
            start = 4
            var length = Int(_u32(data, 0, len(data)))
            if length > len(data) - start:
                raise Error("Definition levels exceed page")
            end = start + length
    elif h.page_type == 3:
        if h.repetition_levels_byte_length != 0:
            raise Error("Flat column has repetition levels")
        end = h.definition_levels_byte_length
        if end < 0 or end > len(data) or (not nullable and end != 0):
            raise Error("Invalid definition-level length")
    else:
        raise Error("Expected a data page")
    var present = h.num_values
    if nullable:
        present = _definition_levels(
            data, start, end, h.num_values, validity, output
        )
    if h.page_type == 3 and h.num_nulls != h.num_values - present:
        raise Error("V2 null count disagrees with levels")
    return end, present


def _page_body(
    var bytes: List[UInt8], h: PageHeader, codec: Int
) raises -> List[UInt8]:
    """Decode one bounded body, preserving V2's uncompressed level prefix."""
    validate_codec(codec)
    if len(bytes) != h.compressed_page_size:
        raise Error("Page body length disagrees with header")
    if codec == 0 or (h.page_type == 3 and not h.is_compressed):
        if len(bytes) != h.uncompressed_page_size:
            raise Error("Uncompressed page body sizes disagree")
        return bytes^
    if h.page_type == 0 or h.page_type == 2:
        return decompress(codec, bytes, h.uncompressed_page_size)
    if h.page_type != 3:
        raise Error("Expected a data page")
    if (
        h.repetition_levels_byte_length < 0
        or h.definition_levels_byte_length < 0
    ):
        raise Error("Negative V2 level length")
    var levels = (
        h.repetition_levels_byte_length + h.definition_levels_byte_length
    )
    if levels < 0 or levels > len(bytes) or levels > h.uncompressed_page_size:
        raise Error("V2 levels exceed page body")
    var values = decompress(
        codec, bytes, h.uncompressed_page_size - levels, levels
    )
    if levels == 0:
        return values^
    var body = List[UInt8](capacity=h.uncompressed_page_size)
    body.extend(Span(bytes)[:levels])
    body.extend(Span(values))
    return body^
