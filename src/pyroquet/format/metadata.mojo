"""Parquet schema and column metadata over the independent Compact codec.

Enum values follow parquet.thrift. -1 denotes an absent optional numeric field.
Logical annotations other than INTEGER are identified, but their payloads are
not interpreted. Metadata objects are inspection snapshots, not execution tables.
Unknown positive enum/annotation IDs remain inspectable for forward compatibility.
"""
from compact_protocol import (
    CompactReader,
    CompactLimits,
    CompactType,
    FieldHeader,
)
from .footer import _expect, _struct_list, _read_footer_bytes


struct SchemaElement(Copyable, Movable):
    var name: String
    var physical_type: Int
    var type_length: Int
    var repetition: Int
    var num_children: Int
    var converted_type: Int
    var logical_type: Int
    var integer_width: Int
    var integer_signed: Bool
    var parent: Int
    var max_definition_level: Int
    var max_repetition_level: Int
    var path: List[String]

    def __init__(out self):
        self.name = String()
        self.physical_type = -1
        self.type_length = -1
        self.repetition = -1
        self.num_children = -1
        self.converted_type = -1
        self.logical_type = -1
        self.integer_width = 0
        self.integer_signed = True
        self.parent = -1
        self.max_definition_level = 0
        self.max_repetition_level = 0
        self.path = List[String]()

    def is_group(self) -> Bool:
        return self.physical_type == -1

    def nullable(self) -> Bool:
        """Whether this field itself is OPTIONAL; ancestors may also be null."""
        return self.repetition == 1


struct ColumnChunk(Copyable, Movable):
    var physical_type: Int
    var path: List[String]
    var codec: Int
    var encodings: List[Int]
    var num_values: Int64
    var total_uncompressed_size: Int64
    var total_compressed_size: Int64
    var data_page_offset: Int64
    var dictionary_page_offset: Int64
    var index_page_offset: Int64
    var file_offset: Int64
    var file_path: String
    var offset_index_offset: Int64
    var offset_index_length: Int64
    var column_index_offset: Int64
    var column_index_length: Int64
    var bloom_filter_offset: Int64
    var bloom_filter_length: Int64
    var schema_index: Int

    def __init__(out self):
        self.physical_type = -1
        self.path = List[String]()
        self.codec = -1
        self.encodings = List[Int]()
        self.num_values = -1
        self.total_uncompressed_size = -1
        self.total_compressed_size = -1
        self.data_page_offset = -1
        self.dictionary_page_offset = -1
        self.index_page_offset = -1
        self.file_offset = 0
        self.file_path = String()
        self.offset_index_offset = -1
        self.offset_index_length = -1
        self.column_index_offset = -1
        self.column_index_length = -1
        self.bloom_filter_offset = -1
        self.bloom_filter_length = -1
        self.schema_index = -1


struct RowGroup(Copyable, Movable):
    var columns: List[ColumnChunk]
    var num_rows: Int64
    var total_byte_size: Int64
    var total_compressed_size: Int64
    var file_offset: Int64

    def __init__(out self):
        self.columns = List[ColumnChunk]()
        self.num_rows = -1
        self.total_byte_size = -1
        self.total_compressed_size = -1
        self.file_offset = -1


struct FileMetadata(Copyable, Movable):
    var version: Int
    var num_rows: Int64
    var schema: List[SchemaElement]
    var row_groups: List[RowGroup]

    def __init__(out self):
        self.version = 0
        self.num_rows = -1
        self.schema = List[SchemaElement]()
        self.row_groups = List[RowGroup]()


def _seen(mut seen: Int, field: FieldHeader, last: Int) raises:
    if field.field_id > 0 and field.field_id <= last:
        var bit = 1 << field.field_id
        if seen & bit:
            raise Error(
                "Duplicate Parquet metadata field " + String(field.field_id)
            )
        seen |= bit


def _i32(mut r: CompactReader, f: FieldHeader) raises -> Int:
    _expect(f, CompactType.I32)
    return Int(r.read_i32())


def _nonnegative(
    mut r: CompactReader, f: FieldHeader, wide: Bool = True
) raises -> Int64:
    var value: Int64
    if wide:
        _expect(f, CompactType.I64)
        value = r.read_i64()
    else:
        value = Int64(_i32(r, f))
    if value < 0:
        raise Error("Negative Parquet count, offset, or length")
    return value


def _strings(mut r: CompactReader, f: FieldHeader) raises -> List[String]:
    _expect(f, CompactType.LIST)
    var h = r.read_collection()
    if h.kind != CompactType.BINARY and not (
        h.size == 0 and h.kind == CompactType.STOP
    ):
        raise Error("Expected list of strings")
    var values = List[String]()
    for _ in range(h.size):
        values.append(r.read_string())
    return values^


def _logical(mut r: CompactReader, mut node: SchemaElement) raises:
    r.begin_struct()
    var count = 0
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        count += 1
        _expect(f, CompactType.STRUCT)
        node.logical_type = f.field_id
        if f.field_id != 10:
            r.skip_field(f)
            continue
        r.begin_struct()
        var seen = 0
        while True:
            var child = r.next_field()
            if child.kind == CompactType.STOP:
                break
            _seen(seen, child, 2)
            if child.field_id == 1:
                _expect(child, CompactType.BYTE)
                node.integer_width = Int(r.read_byte())
            elif child.field_id == 2:
                node.integer_signed = child.boolean()
            else:
                r.skip_field(child)
        r.end_struct()
        if seen != 6:
            raise Error("Missing INTEGER annotation fields")
    r.end_struct()
    if count != 1:
        raise Error("LogicalType must contain exactly one union member")


def _schema_element(mut r: CompactReader) raises -> SchemaElement:
    var node = SchemaElement()
    var seen = 0
    r.begin_struct()
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        _seen(seen, f, 10)
        if f.field_id == 4:
            _expect(f, CompactType.BINARY)
            node.name = r.read_string()
        elif f.field_id == 10:
            _expect(f, CompactType.STRUCT)
            _logical(r, node)
        elif f.field_id == 1:
            node.physical_type = Int(_nonnegative(r, f, False))
        elif f.field_id == 2:
            node.type_length = Int(_nonnegative(r, f, False))
        elif f.field_id == 3:
            node.repetition = Int(_nonnegative(r, f, False))
        elif f.field_id == 5:
            node.num_children = Int(_nonnegative(r, f, False))
        elif f.field_id == 6:
            node.converted_type = Int(_nonnegative(r, f, False))
        else:
            r.skip_field(f)
    r.end_struct()
    if not (seen & 16):
        raise Error("Missing schema name")
    # Modern LogicalType takes precedence; legacy is a fallback only.
    if (
        node.logical_type == -1
        and node.converted_type >= 11
        and node.converted_type <= 18
    ):
        node.integer_width = 8 << ((node.converted_type - 11) % 4)
        node.integer_signed = node.converted_type >= 15
    elif node.logical_type == -1 and node.converted_type == -1:
        if node.physical_type == 1:
            node.integer_width = 32
        elif node.physical_type == 2:
            node.integer_width = 64
    var width = node.integer_width
    if width != 0:
        var compatible = (
            width == 8 or width == 16 or width == 32
        ) and node.physical_type == 1
        compatible = compatible or (width == 64 and node.physical_type == 2)
        if not compatible:
            # LogicalTypes.md: unknown logical/physical combinations use physical type only.
            node.integer_width = 0
    return node^


def _resolve_schema(mut nodes: List[SchemaElement], max_depth: Int) raises:
    if len(nodes) == 0 or not nodes[0].is_group() or nodes[0].num_children < 0:
        raise Error("Schema requires a group root")
    if nodes[0].repetition != -1 and nodes[0].repetition != 0:
        raise Error("Root cannot be optional or repeated")
    var parents = List[Int]()
    var remaining = List[Int]()
    var names = Dict[String, Bool]()
    parents.append(0)
    remaining.append(nodes[0].num_children)
    for i in range(1, len(nodes)):
        while len(remaining) > 0:
            if remaining[len(remaining) - 1] != 0:
                break
            _ = remaining.pop()
            _ = parents.pop()
        if len(parents) == 0:
            raise Error("Schema has extra nodes outside root")
        if len(parents) > max_depth:
            raise Error("Schema depth exceeds limit")
        var parent = parents[len(parents) - 1]
        remaining[len(remaining) - 1] -= 1
        nodes[i].parent = parent
        var key = String(parent) + ":" + nodes[i].name
        if key in names:
            raise Error("Duplicate sibling schema name")
        names[key] = True
        nodes[i].path = nodes[parent].path.copy()
        nodes[i].path.append(nodes[i].name)
        var repetition = nodes[i].repetition
        if repetition < 0 or repetition > 2:
            raise Error("Missing or invalid schema repetition")
        nodes[i].max_definition_level = nodes[
            parent
        ].max_definition_level + Int(repetition != 0)
        nodes[i].max_repetition_level = nodes[
            parent
        ].max_repetition_level + Int(repetition == 2)
        if nodes[i].is_group():
            if nodes[i].num_children < 0:
                raise Error("Group is missing child count")
            parents.append(i)
            remaining.append(nodes[i].num_children)
        elif nodes[i].num_children != -1:
            raise Error("Primitive cannot have children")
        if nodes[i].physical_type == 7 and nodes[i].type_length <= 0:
            raise Error("FIXED_LEN_BYTE_ARRAY requires positive type_length")
    for n in remaining:
        if n != 0:
            raise Error("Schema is missing children")


def _column_metadata(mut r: CompactReader, mut col: ColumnChunk) raises:
    var seen = 0
    r.begin_struct()
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        _seen(seen, f, 17)
        if f.field_id == 1:
            col.physical_type = Int(_nonnegative(r, f, False))
        elif f.field_id == 2:
            _expect(f, CompactType.LIST)
            var h = r.read_collection()
            if h.kind != CompactType.I32 and not (
                h.size == 0 and h.kind == CompactType.STOP
            ):
                raise Error("Expected encoding enum list")
            for _ in range(h.size):
                var encoding = Int(r.read_i32())
                if encoding < 0:
                    raise Error("Negative encoding enum")
                col.encodings.append(encoding)
        elif f.field_id == 3:
            col.path = _strings(r, f)
        elif f.field_id == 4:
            col.codec = Int(_nonnegative(r, f, False))
        elif f.field_id == 5:
            col.num_values = _nonnegative(r, f)
        elif f.field_id == 6:
            col.total_uncompressed_size = _nonnegative(r, f)
        elif f.field_id == 7:
            col.total_compressed_size = _nonnegative(r, f)
        elif f.field_id == 9:
            col.data_page_offset = _nonnegative(r, f)
        elif f.field_id == 10:
            col.index_page_offset = _nonnegative(r, f)
        elif f.field_id == 11:
            col.dictionary_page_offset = _nonnegative(r, f)
        elif f.field_id == 14:
            col.bloom_filter_offset = _nonnegative(r, f)
        elif f.field_id == 15:
            col.bloom_filter_length = _nonnegative(r, f, False)
        else:
            r.skip_field(f)
    r.end_struct()
    if (seen & 766) != 766:
        raise Error("Missing required ColumnMetaData field")


def _column(mut r: CompactReader) raises -> ColumnChunk:
    var col = ColumnChunk()
    var seen = 0
    r.begin_struct()
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        _seen(seen, f, 9)
        if f.field_id == 1:
            _expect(f, CompactType.BINARY)
            col.file_path = r.read_string()
        elif f.field_id == 2:
            _expect(f, CompactType.I64)
            col.file_offset = r.read_i64()
        elif f.field_id == 3:
            _expect(f, CompactType.STRUCT)
            _column_metadata(r, col)
        elif f.field_id == 8 or f.field_id == 9:
            raise Error("Encrypted column metadata is unsupported")
        elif f.field_id == 4:
            col.offset_index_offset = _nonnegative(r, f)
        elif f.field_id == 5:
            col.offset_index_length = _nonnegative(r, f, False)
        elif f.field_id == 6:
            col.column_index_offset = _nonnegative(r, f)
        elif f.field_id == 7:
            col.column_index_length = _nonnegative(r, f, False)
        else:
            r.skip_field(f)
    r.end_struct()
    if (seen & 12) != 12:
        raise Error("ColumnChunk requires file_offset and plaintext metadata")
    return col^


def _group(mut r: CompactReader) raises -> RowGroup:
    var group = RowGroup()
    var seen = 0
    r.begin_struct()
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        _seen(seen, f, 7)
        if f.field_id == 1:
            var n = _struct_list(r, f)
            for _ in range(n):
                group.columns.append(_column(r))
        elif f.field_id == 2:
            group.total_byte_size = _nonnegative(r, f)
        elif f.field_id == 3:
            group.num_rows = _nonnegative(r, f)
        elif f.field_id == 5:
            group.file_offset = _nonnegative(r, f)
        elif f.field_id == 6:
            group.total_compressed_size = _nonnegative(r, f)
        else:
            r.skip_field(f)
    r.end_struct()
    if (seen & 14) != 14:
        raise Error("Missing required RowGroup fields")
    return group^


def _add(a: Int64, b: Int64) raises -> Int64:
    if b > Int64.MAX - a:
        raise Error("Parquet metadata total overflow")
    return a + b


def _link_columns(mut metadata: FileMetadata) raises:
    var leaves = List[Int]()
    for i in range(len(metadata.schema)):
        if not metadata.schema[i].is_group():
            leaves.append(i)
    var rows = Int64(0)
    for ref group in metadata.row_groups:
        rows = _add(rows, group.num_rows)
        if len(group.columns) != len(leaves):
            raise Error("Row-group columns disagree with schema leaves")
        var uncompressed = Int64(0)
        var compressed = Int64(0)
        for i in range(len(leaves)):
            var leaf = leaves[i]
            if group.columns[i].path != metadata.schema[leaf].path:
                raise Error("Column path/order disagrees with schema")
            if (
                group.columns[i].physical_type
                != metadata.schema[leaf].physical_type
            ):
                raise Error("Column physical type disagrees with schema")
            group.columns[i].schema_index = leaf
            if (
                metadata.schema[leaf].max_repetition_level == 0
                and group.columns[i].num_values != group.num_rows
            ):
                raise Error(
                    "Non-repeated column value count disagrees with rows"
                )
            uncompressed = _add(
                uncompressed, group.columns[i].total_uncompressed_size
            )
            compressed = _add(
                compressed, group.columns[i].total_compressed_size
            )
        if uncompressed != group.total_byte_size:
            raise Error("Row-group uncompressed byte total disagrees")
        if (
            group.total_compressed_size != -1
            and group.total_compressed_size != compressed
        ):
            raise Error("Row-group compressed byte total disagrees")
    if rows != metadata.num_rows:
        raise Error("Footer and row-group row counts disagree")


def parse_metadata(
    var bytes: List[UInt8], limits: CompactLimits = CompactLimits()
) raises -> FileMetadata:
    """Decode and link schema/chunks. File-relative ranges need validate_file_ranges.
    """
    var r = CompactReader(bytes^, limits)
    var result = FileMetadata()
    var seen = 0
    r.begin_struct()
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        _seen(seen, f, 9)
        if f.field_id == 1:
            result.version = _i32(r, f)
        elif f.field_id == 2:
            var n = _struct_list(r, f)
            for _ in range(n):
                result.schema.append(_schema_element(r))
        elif f.field_id == 3:
            result.num_rows = _nonnegative(r, f)
        elif f.field_id == 4:
            var n = _struct_list(r, f)
            for _ in range(n):
                result.row_groups.append(_group(r))
        elif f.field_id == 8 or f.field_id == 9:
            raise Error("Encrypted file metadata is unsupported")
        else:
            r.skip_field(f)
    r.end_struct()
    r.finish()
    if (seen & 30) != 30 or (result.version != 1 and result.version != 2):
        raise Error("Missing footer fields or unsupported version")
    _resolve_schema(result.schema, limits.max_depth)
    _link_columns(result)
    return result^


def _range(offset: Int64, length: Int64, end: Int64) raises:
    if offset < 4 or length < 0 or offset > end or length > end - offset:
        raise Error("Parquet byte range is outside the data region")


def _index_range(offset: Int64, length: Int64, end: Int64) raises:
    if offset == -1 and length == -1:
        return
    _range(offset, length, end)


def validate_file_ranges(metadata: FileMetadata, footer_offset: Int64) raises:
    """Validate local data/index ranges before the footer, without reading pages.

    External chunks cannot be checked against this file and are rejected.
    Bloom filters lacking length can only have their start checked here.
    Deprecated ColumnChunk.file_offset is deliberately not authoritative.
    """
    if footer_offset < 4:
        raise Error("Invalid footer offset")
    for group in metadata.row_groups:
        if group.file_offset != -1 and not (
            group.file_offset == 0 and group.num_rows == 0
        ):
            _range(group.file_offset, 0, footer_offset)
        for col in group.columns:
            if col.file_path.byte_length() != 0:
                raise Error(
                    "External column chunks require a separate file resolver"
                )
            var start = col.data_page_offset
            if col.dictionary_page_offset != -1:
                start = col.dictionary_page_offset
                if (
                    not (col.num_values == 0 and col.data_page_offset == 0)
                    and start >= col.data_page_offset
                ):
                    raise Error("Dictionary page follows first data page")
            # Some writers encode an empty chunk as offset=0,size=0.
            if col.total_compressed_size == 0:
                if (
                    col.num_values != 0
                    or col.dictionary_page_offset != -1
                    or col.total_uncompressed_size != 0
                ):
                    raise Error("Empty chunk has values or a dictionary")
                if start != 0:
                    _range(start, 0, footer_offset)
            else:
                _range(start, col.total_compressed_size, footer_offset)
                var dictionary_only = (
                    col.num_values == 0
                    and col.data_page_offset == 0
                    and col.dictionary_page_offset != -1
                )
                if not dictionary_only and (
                    col.data_page_offset < start
                    or col.data_page_offset >= start + col.total_compressed_size
                ):
                    raise Error("Data page is outside its column chunk")
            if col.index_page_offset != -1:
                _range(col.index_page_offset, 1, footer_offset)
            _index_range(
                col.offset_index_offset, col.offset_index_length, footer_offset
            )
            _index_range(
                col.column_index_offset, col.column_index_length, footer_offset
            )
            if col.bloom_filter_offset != -1:
                var length = col.bloom_filter_length
                if length == -1:
                    length = 1
                _range(col.bloom_filter_offset, length, footer_offset)
            elif col.bloom_filter_length != -1:
                raise Error("Bloom filter length without offset")


def inspect_metadata(
    path: String, limits: CompactLimits = CompactLimits()
) raises -> FileMetadata:
    """Read a local plaintext footer and validate schema, chunks, and file ranges.
    """
    var envelope = _read_footer_bytes(path, limits)
    try:
        var offset = envelope.offset
        var metadata = parse_metadata(envelope^.take_bytes(), limits)
        validate_file_ranges(metadata, offset)
        return metadata^
    except error:
        raise Error(path + ": " + String(error))
