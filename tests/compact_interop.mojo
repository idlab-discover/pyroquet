"""Development-only wire transcoder for Apache Thrift interoperability tests."""
from std.sys import argv
from compact_protocol import CompactReader, CompactWriter, CompactType


def copy_struct(
    mut reader: CompactReader, mut writer: CompactWriter, depth: Int
) raises:
    if depth >= 64:
        raise Error("Test transcoder depth limit")
    reader.begin_struct()
    writer.begin_struct()
    while True:
        var field = reader.next_field()
        if field.kind == CompactType.STOP:
            break
        writer.write_field(field.field_id, field.kind)
        copy_value(reader, writer, field.kind, True, depth + 1)
    reader.end_struct()
    writer.end_struct()


def copy_value(
    mut reader: CompactReader,
    mut writer: CompactWriter,
    kind: Int,
    in_field: Bool,
    depth: Int,
) raises:
    if depth >= 64:
        raise Error("Test transcoder depth limit")
    if kind == CompactType.TRUE or kind == CompactType.FALSE:
        if not in_field:
            writer.write_bool(reader.read_bool())
    elif kind == CompactType.BYTE:
        writer.write_byte(reader.read_byte())
    elif kind == CompactType.I16:
        writer.write_i16(reader.read_i16())
    elif kind == CompactType.I32:
        writer.write_i32(reader.read_i32())
    elif kind == CompactType.I64:
        writer.write_i64(reader.read_i64())
    elif kind == CompactType.DOUBLE:
        writer.write_double(reader.read_double())
    elif kind == CompactType.BINARY:
        var bytes = reader.read_binary()
        writer.write_binary(Span(bytes))
    elif kind == CompactType.UUID:
        var bytes = reader.read_uuid()
        writer.write_uuid(Span(bytes))
    elif kind == CompactType.STRUCT:
        copy_struct(reader, writer, depth + 1)
    elif kind == CompactType.LIST or kind == CompactType.SET:
        var header = reader.read_collection()
        writer.write_collection(header.kind, header.size)
        for _ in range(header.size):
            copy_value(reader, writer, header.kind, False, depth + 1)
    elif kind == CompactType.MAP:
        var header = reader.read_map()
        writer.write_map(header.key_kind, header.value_kind, header.size)
        for _ in range(header.size):
            copy_value(reader, writer, header.key_kind, False, depth + 1)
            copy_value(reader, writer, header.value_kind, False, depth + 1)
    else:
        raise Error("Unexpected wire type")


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("Usage: compact_interop INPUT OUTPUT")
    var file = open(args[1], "r")
    var size = file.seek(0, 2)
    if size > 64 * 1024 * 1024:
        raise Error("Test input too large")
    _ = file.seek(0)
    var bytes = file.read_bytes(Int(size))
    if len(bytes) != Int(size):
        raise Error("Short test input read")
    var reader = CompactReader(bytes^)
    var writer = CompactWriter()
    copy_struct(reader, writer, 0)
    reader.finish()
    var output = writer^.finish()
    var destination = open(args[2], "w")
    destination.write_bytes(output)
