"""Lightweight footer summary and shared bounded file-envelope reader.

The summary API deliberately skips schema/chunk internals. Use
pyroquet.format.inspect_metadata for schema semantics and file-range validation.
"""

from std.io.file import FileHandle
from compact_protocol import (
    CompactReader,
    CompactLimits,
    CompactType,
    FieldHeader,
)


@fieldwise_init
struct FooterSummary(Copyable, Movable):
    var version: Int32
    var num_rows: Int64
    var num_schema_nodes: Int
    var row_group_rows: List[Int64]


def _expect(field: FieldHeader, kind: Int) raises:
    if field.kind != kind:
        raise Error(
            "Parquet metadata field "
            + String(field.field_id)
            + ": wrong Compact type"
        )


def _struct_list(mut reader: CompactReader, field: FieldHeader) raises -> Int:
    _expect(field, CompactType.LIST)
    var header = reader.read_collection()
    if header.kind != CompactType.STRUCT and not (
        header.kind == CompactType.STOP and header.size == 0
    ):
        raise Error("Parquet metadata requires a list of structs")
    return header.size


def _row_group_rows(mut reader: CompactReader) raises -> Int64:
    reader.begin_struct()
    var rows = Int64(-1)
    var seen = 0
    while True:
        var field = reader.next_field()
        if field.kind == CompactType.STOP:
            break
        if field.field_id >= 1 and field.field_id <= 3:
            var bit = 1 << (field.field_id - 1)
            if (seen & bit) != 0:
                raise Error("Duplicate required row-group field")
            seen |= bit
        if field.field_id == 1:
            var count = _struct_list(reader, field)
            for _ in range(count):
                reader.skip_field(FieldHeader(0, CompactType.STRUCT))
        elif field.field_id == 2:
            _expect(field, CompactType.I64)
            if reader.read_i64() < 0:
                raise Error("Negative row-group byte size")
        elif field.field_id == 3:
            _expect(field, CompactType.I64)
            rows = reader.read_i64()
        else:
            reader.skip_field(field)
    reader.end_struct()
    if seen != 7 or rows < 0:
        raise Error("Missing or invalid required row-group fields")
    return rows


def parse_footer(
    var bytes: List[UInt8], limits: CompactLimits = CompactLimits()
) raises -> FooterSummary:
    var reader = CompactReader(bytes^, limits)
    reader.begin_struct()
    var seen = 0
    var version = Int32(0)
    var rows = Int64(-1)
    var schema_nodes = 0
    var groups = List[Int64]()
    var total_rows = Int64(0)
    while True:
        var field = reader.next_field()
        if field.kind == CompactType.STOP:
            break
        if field.field_id >= 1 and field.field_id <= 4:
            var bit = 1 << (field.field_id - 1)
            if (seen & bit) != 0:
                raise Error("Duplicate required footer field")
            seen |= bit
        if field.field_id == 1:
            _expect(field, CompactType.I32)
            version = reader.read_i32()
        elif field.field_id == 2:
            schema_nodes = _struct_list(reader, field)
            for _ in range(schema_nodes):
                reader.skip_field(FieldHeader(0, CompactType.STRUCT))
        elif field.field_id == 3:
            _expect(field, CompactType.I64)
            rows = reader.read_i64()
        elif field.field_id == 4:
            var count = _struct_list(reader, field)
            for _ in range(count):
                var group_rows = _row_group_rows(reader)
                if group_rows > Int64.MAX - total_rows:
                    raise Error("Parquet row count overflow")
                total_rows += group_rows
                groups.append(group_rows)
        else:
            reader.skip_field(field)
    reader.end_struct()
    reader.finish()
    if seen != 15 or schema_nodes == 0 or rows < 0:
        raise Error("Missing or invalid required footer fields")
    if version != 1 and version != 2:
        raise Error("Unsupported Parquet metadata version")
    if rows != total_rows:
        raise Error("Footer and row-group row counts disagree")
    return FooterSummary(version, rows, schema_nodes, groups^)


@fieldwise_init
struct _FooterBytes(Movable):
    var bytes: List[UInt8]
    var offset: Int64

    def take_bytes(deinit self) -> List[UInt8]:
        return self.bytes^


def _read_footer_bytes_from_file(
    mut file: FileHandle, path: String, limits: CompactLimits = CompactLimits()
) raises -> _FooterBytes:
    """Read only magic, trailer and bounded footer bytes from one open handle.
    """
    limits.validate()
    var size = file.seek(0, 2)
    if size < 12 or size > UInt64(Int.MAX):
        raise Error(path + ": invalid Parquet file size")
    _ = file.seek(0)
    var magic = file.read_bytes(4)
    if magic != [UInt8(80), 65, 82, 49]:
        raise Error(path + ": unsupported or invalid Parquet magic")
    _ = file.seek(Int(size) - 8)
    var tail = file.read_bytes(8)
    if len(tail) != 8:
        raise Error(path + ": short Parquet trailer read")
    for i in range(4):
        if tail[i + 4] != magic[i]:
            raise Error(path + ": unsupported or invalid Parquet trailer magic")
    var footer_size = UInt32(0)
    for i in range(4):
        footer_size |= UInt32(tail[i]) << UInt32(i * 8)
    if Int(footer_size) > Int(size) - 12 or Int(footer_size) > limits.max_bytes:
        raise Error(path + ": footer length exceeds file bounds or limit")
    _ = file.seek(Int(size) - 8 - Int(footer_size))
    var bytes = file.read_bytes(Int(footer_size))
    if len(bytes) != Int(footer_size):
        raise Error(path + ": short Parquet footer read")
    return _FooterBytes(bytes^, Int64(size) - 8 - Int64(footer_size))


def _read_footer_bytes(
    path: String, limits: CompactLimits = CompactLimits()
) raises -> _FooterBytes:
    var file = open(path, "r")
    return _read_footer_bytes_from_file(file, path, limits)


def inspect_footer(
    path: String, limits: CompactLimits = CompactLimits()
) raises -> FooterSummary:
    var envelope = _read_footer_bytes(path, limits)
    try:
        return parse_footer(envelope^.take_bytes(), limits)
    except error:
        raise Error(path + ": " + String(error))
