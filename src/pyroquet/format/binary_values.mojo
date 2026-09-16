"""Bounded physical binary payloads; no logical text conversion."""

from ..binary_column import BinaryColumn, BinaryBuilder


def decode_plain_binary(
    data: List[UInt8],
    count: Int,
    fixed_width: Int = 0,
    max_bytes: Int = 1073741824,
) raises -> BinaryColumn:
    """Validate the entire payload before allocating the decoded arena.

    Count describes present values (or dictionary entries), not nullable rows.
    Fixed-width multiplication is checked through division before any copy.
    """
    if count < 0 or fixed_width < 0 or max_bytes < 0:
        raise Error("Invalid binary payload limits")
    if count >= Int.MAX // 8:
        raise Error("Binary offset allocation overflow")
    var pos = 0
    var total = 0
    if fixed_width != 0:
        if count > len(data) // fixed_width or count * fixed_width != len(data):
            raise Error("Fixed binary payload length mismatch")
        total = len(data)
    else:
        for _ in range(count):
            var width = _length(data, pos)
            pos += 4
            if width > len(data) - pos:
                raise Error("Truncated binary value")
            if width > max_bytes - total:
                raise Error("Binary byte budget exceeded")
            total += width
            pos += width
        if pos != len(data):
            raise Error("Trailing binary payload bytes")
    if total > max_bytes:
        raise Error("Binary byte budget exceeded")
    var builder = BinaryBuilder(max_bytes, fixed_width)
    pos = 0
    for _ in range(count):
        var width = fixed_width
        if fixed_width == 0:
            width = _length(data, pos)
            pos += 4
        builder.append(Span(data)[pos : pos + width])
        pos += width
    return builder^.freeze()


def _length(data: List[UInt8], pos: Int) raises -> Int:
    if pos < 0 or pos > len(data) or len(data) - pos < 4:
        raise Error("Truncated binary length prefix")
    var result = UInt32(0)
    for i in range(4):
        result |= UInt32(data[pos + i]) << UInt32(8 * i)
    # BYTE_ARRAY lengths cannot exceed the signed i32 page-size domain.
    if result > 2147483647:
        raise Error("Binary value length exceeds signed page size")
    return Int(result)


def encode_plain_binary(
    column: BinaryColumn,
    start: Int,
    count: Int,
    max_bytes: Int,
) raises -> List[UInt8]:
    """Skip null rows; reject values/pages larger than the explicit byte budget.
    """
    if (
        start < 0
        or count < 0
        or start > len(column)
        or count > len(column) - start
        or max_bytes < 0
    ):
        raise Error("Invalid binary encoding range or budget")
    var total = 0
    for i in range(start, start + count):
        if column.is_valid(i):
            var width = len(column.value(i))
            var prefix = 4 if column.fixed_width() == 0 else 0
            if width > 2147483647 or prefix > max_bytes - total:
                raise Error("Binary page byte budget exceeded")
            total += prefix
            if width > max_bytes - total:
                raise Error("Binary page byte budget exceeded")
            total += width
    var result = List[UInt8]()
    result.reserve(total)
    for i in range(start, start + count):
        if not column.is_valid(i):
            continue
        var bytes = column.value(i)
        if column.fixed_width() == 0:
            var width = UInt32(len(bytes))
            for j in range(4):
                result.append(UInt8((width >> UInt32(j * 8)) & 255))
        for byte in bytes:
            result.append(byte)
    return result^
