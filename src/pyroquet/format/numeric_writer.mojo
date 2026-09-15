"""Bounded metadata emission for a single numeric PLAIN column."""
from compact_protocol import CompactWriter, CompactType, CompactLimits


@fieldwise_init
struct _WrittenGroup(ImplicitlyCopyable):
    var offset: Int64
    var size: Int64
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
) raises -> List[UInt8]:
    var writer = CompactWriter(CompactLimits(max_bytes=128))
    writer.begin_struct()
    _i32(writer, 1, 0 if page_version == 1 else 3)  # DATA_PAGE / DATA_PAGE_V2
    _i32(writer, 2, body_size)
    _i32(writer, 3, body_size)
    writer.write_field(5 if page_version == 1 else 8, CompactType.STRUCT)
    writer.begin_struct()
    _i32(writer, 1, rows)
    if page_version == 1:
        _i32(writer, 2, 0)  # PLAIN
        _i32(writer, 3, 3)  # RLE definition levels
        _i32(writer, 4, 3)  # RLE repetition levels (absent for flat fields)
    else:
        _i32(writer, 2, nulls)
        _i32(writer, 3, rows)  # Flat values are whole rows
        _i32(writer, 4, 0)  # PLAIN
        _i32(writer, 5, definition_bytes)
        _i32(writer, 6, 0)  # No repetition-level stream
        writer.write_bool_field(7, False)  # Values are explicitly uncompressed
    writer.end_struct()
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
) raises -> List[UInt8]:
    var writer = CompactWriter(CompactLimits(max_bytes=max_bytes))
    writer.begin_struct()
    _i32(writer, 1, 1)  # File metadata version
    writer.write_field(2, CompactType.LIST)
    writer.write_collection(CompactType.STRUCT, 2)
    writer.begin_struct()
    _string(writer, 4, "schema")
    _i32(writer, 5, 1)
    writer.end_struct()
    writer.begin_struct()
    _i32(writer, 1, physical)
    _i32(writer, 3, 1 if nullable else 0)
    _string(writer, 4, name)
    if integer_width != 0:
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
    _i64(writer, 3, Int64(rows))
    writer.write_field(4, CompactType.LIST)
    writer.write_collection(CompactType.STRUCT, len(groups))
    for group in groups:
        writer.begin_struct()  # RowGroup
        writer.write_field(1, CompactType.LIST)
        writer.write_collection(CompactType.STRUCT, 1)
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
        _i32(writer, 4, 0)  # UNCOMPRESSED
        _i64(writer, 5, group.rows)
        _i64(writer, 6, group.size)
        _i64(writer, 7, group.size)
        _i64(writer, 9, group.offset)
        writer.write_field(
            12, CompactType.STRUCT
        )  # Statistics: null count only
        writer.begin_struct()
        _i64(writer, 3, group.nulls)
        writer.end_struct()
        writer.end_struct()
        writer.end_struct()
        _i64(writer, 2, group.size)
        _i64(writer, 3, group.rows)
        _i64(writer, 5, group.offset)
        _i64(writer, 6, group.size)
        writer.end_struct()
    _string(writer, 6, "pyroquet numeric writer")
    writer.end_struct()
    return writer^.finish()
