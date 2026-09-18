"""PLAIN Boolean/binary pages with bounded staging and no text interpretation."""
from .table import Column
from .schema import SchemaNode
from .io import NewFile
from .format.page_write import NumericWriteOptions, _append_u32, _write_page
from .format.flat_writer import _WrittenGroup
from .format.binary_values import encode_plain_binary
from .format.boolean_values import encode_plain_boolean


def _encode_plain_enum(
    column: Column, start: Int, count: Int, max_bytes: Int
) raises -> List[UInt8]:
    """Resolve indices into bounded PLAIN pages without expanding the column."""
    ref enumeration = column.enumeration()
    if (
        start < 0
        or count < 0
        or start > len(enumeration)
        or count > len(enumeration) - start
        or max_bytes < 0
    ):
        raise Error("Invalid ENUM encoding range or budget")
    var total = 0
    for i in range(start, start + count):
        if enumeration.is_valid(i):
            var width = len(column._byte_value(i))
            if width > 2147483647 or 4 > max_bytes - total:
                raise Error("ENUM page byte budget exceeded")
            total += 4
            if width > max_bytes - total:
                raise Error("ENUM page byte budget exceeded")
            total += width
    var result = List[UInt8](capacity=total)
    for i in range(start, start + count):
        if enumeration.is_valid(i):
            var bytes = column._byte_value(i)
            _append_u32(result, UInt32(len(bytes)))
            result.extend(bytes)
    return result^


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
                    elif column.kind() == SchemaNode.ENUM:
                        valid = column.enumeration().is_valid(start + index)
                    else:
                        valid = column._binary_storage().is_valid(start + index)
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
    elif column.kind() == SchemaNode.ENUM:
        values = _encode_plain_enum(
            column, start, count, max_bytes - level_bytes
        )
    else:
        values = encode_plain_binary(
            column._binary_storage(), start, count, max_bytes - level_bytes
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
