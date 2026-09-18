"""Bounded footer and header emission for flat PLAIN column chunks."""
from compact_protocol import CompactWriter, CompactType, CompactLimits


@fieldwise_init
struct _WrittenGroup(ImplicitlyCopyable):
    var offset: Int64
    var size: Int64
    var uncompressed_size: Int64
    var rows: Int64
    var nulls: Int64


def _i32(mut writer: CompactWriter, field: Int, value: Int) raises:
    writer.write_field(field, CompactType.I32)
    writer.write_i32(Int32(value))


def _i64(mut writer: CompactWriter, field: Int, value: Int64) raises:
    writer.write_field(field, CompactType.I64)
    writer.write_i64(value)


def _string(mut writer: CompactWriter, field: Int, value: String) raises:
    writer.write_field(field, CompactType.BINARY)
    writer.write_string(value)


def _plain_header(
    rows: Int,
    body_size: Int,
    page_version: Int = 1,
    nulls: Int = 0,
    definition_bytes: Int = 0,
    compressed_size: Int = -1,
    is_compressed: Bool = False,
    num_rows: Int = -1,
    repetition_bytes: Int = 0,
) raises -> List[UInt8]:
    var writer = CompactWriter(CompactLimits(max_bytes=128))
    writer.begin_struct()
    _i32(writer, 1, 0 if page_version == 1 else 3)  # DATA_PAGE / DATA_PAGE_V2
    _i32(writer, 2, body_size)
    _i32(writer, 3, body_size if compressed_size < 0 else compressed_size)
    writer.write_field(5 if page_version == 1 else 8, CompactType.STRUCT)
    writer.begin_struct()
    _i32(writer, 1, rows)
    if page_version == 1:
        _i32(writer, 2, 0)  # PLAIN
        _i32(writer, 3, 3)  # RLE definition levels
        _i32(writer, 4, 3)  # RLE repetition levels (absent for flat fields)
    else:
        _i32(writer, 2, nulls)
        _i32(writer, 3, rows if num_rows < 0 else num_rows)
        _i32(writer, 4, 0)  # PLAIN
        _i32(writer, 5, definition_bytes)
        _i32(writer, 6, repetition_bytes)
        writer.write_bool_field(7, is_compressed)
    writer.end_struct()
    writer.end_struct()
    return writer^.finish()


struct _WrittenField(Copyable, Movable):
    var name: String
    var physical: Int
    var integer_width: Int
    var signed: Bool
    var nullable: Bool
    var codec: Int
    var fixed_width: Int
    var is_string: Bool
    var is_enum: Bool

    def __init__(
        out self,
        var name: String,
        physical: Int,
        integer_width: Int,
        signed: Bool,
        nullable: Bool,
        codec: Int,
        fixed_width: Int,
        is_string: Bool = False,
        is_enum: Bool = False,
    ):
        self.name = name^
        self.physical = physical
        self.integer_width = integer_width
        self.signed = signed
        self.nullable = nullable
        self.codec = codec
        self.fixed_width = fixed_width
        self.is_string = is_string
        self.is_enum = is_enum


def _write_schema_field(mut writer: CompactWriter, field: _WrittenField) raises:
    var physical = field.physical
    var nullable = field.nullable
    var name = field.name.copy()
    var integer_width = field.integer_width
    var signed = field.signed
    writer.begin_struct()
    _i32(writer, 1, physical)
    if physical == 7:
        _i32(writer, 2, field.fixed_width)
    _i32(writer, 3, 1 if nullable else 0)
    _string(writer, 4, name)
    if field.is_string or field.is_enum:
        _i32(writer, 6, 4 if field.is_enum else 0)  # ENUM / UTF8
        writer.write_field(10, CompactType.STRUCT)  # LogicalType
        writer.begin_struct()
        writer.write_field(4 if field.is_enum else 1, CompactType.STRUCT)
        writer.begin_struct()
        writer.end_struct()
        writer.end_struct()
    elif integer_width != 0:
        var index = 0
        var width = 8
        while width < integer_width:
            width *= 2
            index += 1
        _i32(writer, 6, (15 if signed else 11) + index)
        writer.write_field(10, CompactType.STRUCT)  # LogicalType
        writer.begin_struct()
        writer.write_field(10, CompactType.STRUCT)  # INTEGER
        writer.begin_struct()
        writer.write_field(1, CompactType.BYTE)
        writer.write_byte(Int8(integer_width))
        writer.write_bool_field(2, signed)
        writer.end_struct()
        writer.end_struct()
    writer.end_struct()


def _write_chunk(
    mut writer: CompactWriter, field: _WrittenField, chunk: _WrittenGroup
) raises:
    var physical = field.physical
    var nullable = field.nullable
    var name = field.name.copy()
    var codec = field.codec
    writer.begin_struct()  # ColumnChunk
    _i64(writer, 2, 0)  # Deprecated file_offset; metadata lives in footer
    writer.write_field(3, CompactType.STRUCT)
    writer.begin_struct()  # ColumnMetaData
    _i32(writer, 1, physical)
    writer.write_field(2, CompactType.LIST)
    writer.write_collection(CompactType.I32, 2 if nullable else 1)
    writer.write_i32(0)  # PLAIN
    if nullable:
        writer.write_i32(3)  # RLE levels
    writer.write_field(3, CompactType.LIST)
    writer.write_collection(CompactType.BINARY, 1)
    writer.write_string(name)
    _i32(writer, 4, codec)
    _i64(writer, 5, chunk.rows)
    _i64(writer, 6, chunk.uncompressed_size)
    _i64(writer, 7, chunk.size)
    _i64(writer, 9, chunk.offset)
    writer.write_field(12, CompactType.STRUCT)  # Statistics: null count only
    writer.begin_struct()
    _i64(writer, 3, chunk.nulls)
    writer.end_struct()
    writer.end_struct()
    writer.end_struct()


def _table_footer(
    fields: List[_WrittenField],
    rows: Int,
    chunks: List[_WrittenGroup],
    group_count: Int,
    max_bytes: Int,
) raises -> List[UInt8]:
    var writer = CompactWriter(CompactLimits(max_bytes=max_bytes))
    writer.begin_struct()
    _i32(writer, 1, 1)
    writer.write_field(2, CompactType.LIST)
    writer.write_collection(CompactType.STRUCT, len(fields) + 1)
    writer.begin_struct()
    _string(writer, 4, "schema")
    _i32(writer, 5, len(fields))
    writer.end_struct()
    for field in fields:
        _write_schema_field(writer, field)
    _i64(writer, 3, Int64(rows))
    writer.write_field(4, CompactType.LIST)
    writer.write_collection(CompactType.STRUCT, group_count)
    for g in range(group_count):
        writer.begin_struct()
        writer.write_field(1, CompactType.LIST)
        writer.write_collection(CompactType.STRUCT, len(fields))
        var raw_size = Int64(0)
        var stored_size = Int64(0)
        for c in range(len(fields)):
            var chunk = chunks[g * len(fields) + c]
            _write_chunk(writer, fields[c], chunk)
            if (
                chunk.uncompressed_size > Int64.MAX - raw_size
                or chunk.size > Int64.MAX - stored_size
            ):
                raise Error("Row-group byte size overflow")
            raw_size += chunk.uncompressed_size
            stored_size += chunk.size
        var first = chunks[g * len(fields)]
        _i64(writer, 2, raw_size)
        _i64(writer, 3, first.rows)
        _i64(writer, 5, first.offset)
        _i64(writer, 6, stored_size)
        writer.end_struct()
    _string(writer, 6, "pyroquet numeric writer")
    writer.end_struct()
    return writer^.finish()


def _numeric_footer(
    name: String,
    physical: Int,
    integer_width: Int,
    signed: Bool,
    nullable: Bool,
    rows: Int,
    groups: List[_WrittenGroup],
    max_bytes: Int,
    codec: Int = 0,
) raises -> List[UInt8]:
    var fields = List[_WrittenField]()
    fields.append(
        _WrittenField(
            name.copy(), physical, integer_width, signed, nullable, codec, 0
        )
    )
    return _table_footer(fields, rows, groups, len(groups), max_bytes)
