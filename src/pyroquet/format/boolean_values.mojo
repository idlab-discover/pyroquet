"""Boolean physical value payloads independent of definition-level validity."""

from ..boolean_column import BooleanColumn
from .hybrid import _HybridDecoder


def decode_boolean_values(
    data: List[UInt8], count: Int, encoding: Int = 0
) raises -> BooleanColumn:
    if count < 0:
        raise Error("Negative Boolean present count")
    var size = count // 8 + Int(count % 8 != 0)
    if encoding == 0:
        if len(data) != size:
            raise Error("Boolean PLAIN length mismatch")
        var values = data.copy()
        if count % 8 != 0:
            values[size - 1] &= (UInt8(1) << UInt8(count % 8)) - 1
        return BooleanColumn(count, values^)
    if encoding != 3:
        raise Error("Unsupported Boolean value encoding")
    if len(data) < 4:
        raise Error("Truncated Boolean RLE length")
    var length = UInt32(0)
    for i in range(4):
        length |= UInt32(data[i]) << UInt32(i * 8)
    if Int(length) != len(data) - 4:
        raise Error("Boolean RLE length mismatch")
    var decoder = _HybridDecoder(4, len(data), 1, count)
    var values = List[UInt8]()
    for _ in range(size):
        values.append(0)
    for i in range(count):
        if decoder.next(data) != 0:
            values[i // 8] |= UInt8(1) << UInt8(i % 8)
    decoder.finish()
    return BooleanColumn(count, values^)


def encode_plain_boolean(
    column: BooleanColumn, start: Int, count: Int
) raises -> List[UInt8]:
    if (
        start < 0
        or count < 0
        or start > len(column)
        or count > len(column) - start
    ):
        raise Error("Boolean encoding row range outside column")
    var result = List[UInt8]()
    var present = 0
    for i in range(start, start + count):
        var value = column.value(i)
        if not value:
            continue
        if present % 8 == 0:
            result.append(0)
        if value.value():
            result[present // 8] |= UInt8(1) << UInt8(present % 8)
        present += 1
    return result^
