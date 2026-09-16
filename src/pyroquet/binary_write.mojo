"""PLAIN Boolean/binary pages with bounded staging and no text interpretation."""
from .table import Column
from .schema import SchemaNode
from .io import NewFile
from .numojo_write import NumericWriteOptions, _append_u32, _write_page
from .format.numeric_writer import _WrittenGroup
from .format.binary_values import encode_plain_binary
from .format.boolean_values import encode_plain_boolean


def _binary_page(
    column: Column,
    start: Int,
    count: Int,
    nullable: Bool,
    mut nulls: Int,
    page_version: Int,
    max_bytes: Int,
    mut level_bytes: Int,
) raises -> List[UInt8]:
    var levels = List[UInt8]()
    var groups = count // 8 + Int(count % 8 != 0)
    if nullable:
        var header = UInt32(groups * 2 + 1)
        while header >= 128:
            levels.append(UInt8(header & 127) | 128)
            header >>= 7
        levels.append(UInt8(header))
        for g in range(groups):
            var packed = UInt8(0)
            for bit in range(8):
                var index = g * 8 + bit
                if index < count:
                    var valid: Bool
                    if column.kind() == SchemaNode.BOOLEAN:
                        valid = Bool(column.boolean().value(start + index))
                    else:
                        valid = column.binary().is_valid(start + index)
                    if valid:
                        packed |= UInt8(1) << UInt8(bit)
                    else:
                        nulls += 1
            levels.append(packed)
    var body = List[UInt8]()
    if nullable and page_version == 1:
        _append_u32(body, UInt32(len(levels)))
    for byte in levels:
        body.append(byte)
    level_bytes = len(body)
    if level_bytes > max_bytes:
        raise Error("Binary page levels exceed byte budget")
    var values: List[UInt8]
    if column.kind() == SchemaNode.BOOLEAN:
        if count // 8 + Int(count % 8 != 0) > max_bytes - level_bytes:
            raise Error("Boolean page exceeds byte budget")
        values = encode_plain_boolean(column.boolean(), start, count)
    else:
        values = encode_plain_binary(
            column.binary(), start, count, max_bytes - level_bytes
        )
    body.reserve(level_bytes + len(values))
    for byte in values:
        body.append(byte)
    return body^


def _write_binary_chunk(
    mut file: NewFile,
    column: Column,
    start: Int,
    count: Int,
    options: NumericWriteOptions,
    mut offset: Int64,
) raises -> _WrittenGroup:
    """Emit one borrowed row range, retaining only bounded page staging."""
    var group_offset = offset
    var written = 0
    var nulls = 0
    var uncompressed_size = Int64(0)
    while written < count:
        var page_rows = min(options.page_rows, count - written)
        var page_nulls = 0
        var level_bytes = 0
        var bytes = _binary_page(
            column,
            start + written,
            page_rows,
            options.nullable,
            page_nulls,
            options.page_version,
            options.max_page_bytes,
            level_bytes,
        )
        nulls += page_nulls
        var raw_size = _write_page(
            file, bytes^, page_rows, page_nulls, level_bytes, options, offset
        )
        if raw_size > Int64.MAX - uncompressed_size:
            raise Error("Uncompressed row-group size overflow")
        uncompressed_size += raw_size
        written += page_rows
    return _WrittenGroup(
        group_offset,
        offset - group_offset,
        uncompressed_size,
        Int64(count),
        Int64(nulls),
    )
