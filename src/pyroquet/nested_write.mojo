"""Canonical STRUCT/three-level LIST PLAIN writing with bounded page staging.

The storage tree supplies parent validity and list offsets; typed leaf borrowing
supplies only physical values. Pages end at parent-row boundaries (including V1).
Format authority: parquet-format README Nested Encoding/Nulls/Data Pages,
LogicalTypes Nested Types/LIST, thrift DataPageHeaderV2 and ColumnMetaData.
"""
from std.sys import size_of
from compact_protocol import CompactWriter, CompactType, CompactLimits
from .schema import Schema, SchemaNode
from .table import Column
from .nested_table import NestedTable
from .table_write import TableWriteOptions, ColumnWriteOptions
from .numojo_write import _append_plain
from .io import NewFile
from .format.page_write import NumericWriteOptions, _append_u32, _write_page
from .format.flat_writer import (
    _WrittenGroup,
    _WrittenField,
    _write_schema_field,
    _i32,
    _i64,
    _string,
)


struct _LevelRuns(Movable):
    var data: List[UInt8]
    var width: Int
    var previous: Int
    var count: Int
    var limit: Int

    def __init__(out self, maximum: Int, limit: Int):
        self.data = List[UInt8]()
        self.width = 0
        var remaining = maximum
        while remaining:
            self.width += 1
            remaining >>= 1
        self.previous = 0
        self.count = 0
        self.limit = limit

    def flush(mut self) raises:
        if self.count == 0 or self.width == 0:
            return
        var header = UInt32(self.count) << 1
        var needed = 1 + (self.width + 7) // 8
        var rest = header
        while rest >= 128:
            needed += 1
            rest >>= 7
        if needed > self.limit - len(self.data):
            raise Error("Nested level stream exceeds page byte budget")
        while header >= 128:
            self.data.append(UInt8(header & 127) | 128)
            header >>= 7
        self.data.append(UInt8(header))
        for i in range((self.width + 7) // 8):
            self.data.append(UInt8(self.previous >> (i * 8)))
        self.count = 0

    def append(mut self, value: Int) raises:
        if self.count and value != self.previous:
            self.flush()
        self.previous = value
        self.count += 1


def _nested_field(
    node: SchemaNode, codec: Int, element: Bool
) raises -> _WrittenField:
    var physical = 0
    var width = 0
    var signed = False
    comptime types = (
        DType.int8,
        DType.uint8,
        DType.int16,
        DType.uint16,
        DType.int32,
        DType.uint32,
        DType.int64,
        DType.uint64,
        DType.float32,
        DType.float64,
    )
    comptime for t in range(10):
        comptime dtype = types[t]
        if node.kind() == SchemaNode.numeric_kind[dtype]():
            comptime floating = dtype == DType.float32 or dtype == DType.float64
            physical = (4 if dtype == DType.float32 else 5) if floating else (
                2 if size_of[Scalar[dtype]]() == 8 else 1
            )
            width = 0 if floating else size_of[Scalar[dtype]]() * 8
            signed = dtype.is_signed()
    if node.kind() == SchemaNode.BINARY or node.kind() == SchemaNode.STRING:
        physical = 6
    elif node.kind() == SchemaNode.FIXED_BINARY:
        physical = 7
    return _WrittenField(
        "element" if element else node.name(),
        physical,
        width,
        signed,
        node.nullable(),
        codec,
        node.fixed_width(),
        node.kind() == SchemaNode.STRING,
    )


def _nested_valid(column: Column, index: Int) raises -> Bool:
    if column.kind() == SchemaNode.STRING:
        return column.string().is_valid(index)
    if column.kind() == SchemaNode.BOOLEAN:
        return Bool(column.boolean().value(index))
    if column.kind() >= SchemaNode.BINARY:
        return column.binary().is_valid(index)
    comptime types = (
        DType.int8,
        DType.uint8,
        DType.int16,
        DType.uint16,
        DType.int32,
        DType.uint32,
        DType.int64,
        DType.uint64,
        DType.float32,
        DType.float64,
    )
    comptime for t in range(10):
        comptime dtype = types[t]
        if column.kind() == SchemaNode.numeric_kind[dtype]():
            return Bool(column.numeric[dtype]().value(index))
    raise Error("Unsupported nested leaf")


def _nested_value(
    column: Column,
    index: Int,
    mut bytes: List[UInt8],
    mut present: Int,
    limit: Int,
) raises:
    if column.kind() == SchemaNode.BOOLEAN:
        if present % 8 == 0:
            if len(bytes) == limit:
                raise Error("Nested values exceed page byte budget")
            bytes.append(0)
        if column.boolean().value(index).value():
            bytes[len(bytes) - 1] |= UInt8(1) << UInt8(present % 8)
    elif column.kind() >= SchemaNode.BINARY:
        var value = column._binary_storage().value(index)
        var prefix = 0 if column.kind() == SchemaNode.FIXED_BINARY else 4
        if len(value) > limit - len(bytes) - prefix:
            raise Error("Nested values exceed page byte budget")
        if prefix:
            if len(value) > 2147483647:
                raise Error("Binary value exceeds physical i32 length")
            _append_u32(bytes, UInt32(len(value)))
        for byte in value:
            bytes.append(byte)
    else:
        comptime types = (
            DType.int8,
            DType.uint8,
            DType.int16,
            DType.uint16,
            DType.int32,
            DType.uint32,
            DType.int64,
            DType.uint64,
            DType.float32,
            DType.float64,
        )
        comptime for t in range(10):
            comptime dtype = types[t]
            if column.kind() == SchemaNode.numeric_kind[dtype]():
                comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
                if width > limit - len(bytes):
                    raise Error("Nested values exceed page byte budget")
                _append_plain[dtype](
                    bytes, column.numeric[dtype]().value(index).value()
                )
    present += 1


def _ancestry(schema: Schema, leaf: Int) raises -> List[Int]:
    var reversed = List[Int]()
    var current = leaf
    while current:
        reversed.append(current)
        current = schema.node(current).parent()
    var result = List[Int](capacity=len(reversed))
    for i in range(len(reversed)):
        result.append(reversed[len(reversed) - i - 1])
    return result^


def _nested_chunk(
    mut file: NewFile,
    table: NestedTable,
    schema: Schema,
    leaf: Int,
    leaf_index: Int,
    start: Int,
    count: Int,
    setting: NumericWriteOptions,
    mut offset: Int64,
) raises -> _WrittenGroup:
    var path = _ancestry(schema, leaf)
    var maximum = 0
    var list_node = -1
    for index in path:
        var node = schema.node(index)
        maximum += Int(node.nullable())
        if node.kind() == SchemaNode.LIST:
            list_node = index
            maximum += 1
    var group_offset = offset
    var raw = Int64(0)
    var entries = Int64(0)
    var nulls = Int64(0)
    var written = 0
    while written < count:
        var rows = min(setting.page_rows, count - written)
        var repetitions = _LevelRuns(
            Int(list_node >= 0), setting.max_page_bytes
        )
        var definitions = _LevelRuns(maximum, setting.max_page_bytes)
        var values = List[UInt8]()
        var page_entries = 0
        var present = 0
        for row in range(start + written, start + written + rows):
            if page_entries >= 2147483647:
                raise Error("Nested page exceeds i32 value count")
            var definition = 0
            var absent = False
            for depth in range(len(path) - 1):
                var index = path[depth]
                if not table.structure(index).is_valid(row):
                    absent = True
                    break
                definition += Int(schema.node(index).nullable())
            var first = row
            var end = row + 1
            if list_node >= 0:
                first = table.structure(list_node).offset(row)
                end = table.structure(list_node).offset(row + 1)
                if not absent and end != first:
                    definition += 1  # repeated wrapper is defined
            if absent or first == end:
                repetitions.append(0)
                definitions.append(definition)
                page_entries += 1
            else:
                # Each entry costs bounded bookkeeping even if all values null.
                if end - first > 2147483647 - page_entries:
                    raise Error("Nested page exceeds i32 value count")
                if end - first > setting.max_page_bytes * 8 - page_entries:
                    raise Error(
                        "Nested page child expansion exceeds staging bound"
                    )
                for index in range(first, end):
                    repetitions.append(Int(index != first))
                    var valid = _nested_valid(table.leaf(leaf_index), index)
                    definitions.append(
                        definition + Int(valid and schema.node(leaf).nullable())
                    )
                    if valid:
                        _nested_value(
                            table.leaf(leaf_index),
                            index,
                            values,
                            present,
                            setting.max_page_bytes,
                        )
                    page_entries += 1
            if page_entries > setting.max_page_bytes * 8:
                raise Error("Nested page child expansion exceeds staging bound")
        repetitions.flush()
        definitions.flush()
        var repetition_bytes = len(repetitions.data)
        var definition_bytes = len(definitions.data)
        var prefixes = (
            4 * (Int(list_node >= 0) + Int(maximum > 0))
        ) if setting.page_version == 1 else 0
        var level_bytes = repetition_bytes + definition_bytes + prefixes
        if level_bytes > setting.max_page_bytes - len(values):
            raise Error("Nested page exceeds page byte budget")
        var bytes = List[UInt8](capacity=level_bytes + len(values))
        if list_node >= 0:
            if setting.page_version == 1:
                _append_u32(bytes, UInt32(repetition_bytes))
            for byte in repetitions.data:
                bytes.append(byte)
        if maximum:
            if setting.page_version == 1:
                _append_u32(bytes, UInt32(definition_bytes))
            for byte in definitions.data:
                bytes.append(byte)
        for byte in values:
            bytes.append(byte)
        var page_raw = _write_page(
            file,
            bytes^,
            page_entries,
            page_entries - present,
            level_bytes,
            setting,
            offset,
            rows,
            repetition_bytes,
        )
        if (
            page_raw > Int64.MAX - raw
            or Int64(page_entries) > Int64.MAX - entries
        ):
            raise Error("Nested column chunk size/count overflow")
        raw += page_raw
        entries += Int64(page_entries)
        nulls += Int64(page_entries - present)
        written += rows
    return _WrittenGroup(
        group_offset, offset - group_offset, raw, entries, nulls
    )


def _schema_children(schema: Schema, parent: Int) raises -> Int:
    var count = 0
    for i in range(1, len(schema)):
        count += Int(schema.node(i).parent() == parent)
    return count


def _emit_nested_schema(
    mut writer: CompactWriter, schema: Schema, index: Int
) raises:
    var node = schema.node(index)
    if node.kind() != SchemaNode.GROUP and node.kind() != SchemaNode.LIST:
        var element = schema.node(node.parent()).kind() == SchemaNode.LIST
        _write_schema_field(writer, _nested_field(node, 0, element))
        return
    writer.begin_struct()
    if index:
        _i32(writer, 3, Int(node.nullable()))
    _string(writer, 4, node.name())
    _i32(writer, 5, _schema_children(schema, index))
    if node.kind() == SchemaNode.LIST:
        _i32(writer, 6, 3)  # ConvertedType LIST
        writer.write_field(10, CompactType.STRUCT)
        writer.begin_struct()
        writer.write_field(3, CompactType.STRUCT)  # LogicalType LIST
        writer.begin_struct()
        writer.end_struct()
        writer.end_struct()
    writer.end_struct()
    if node.kind() == SchemaNode.LIST:
        writer.begin_struct()
        _i32(writer, 3, 2)  # REPEATED wrapper
        _string(writer, 4, "list")
        _i32(writer, 5, 1)
        writer.end_struct()
    for child in range(index + 1, len(schema)):
        if schema.node(child).parent() == index:
            _emit_nested_schema(writer, schema, child)


def _leaf_order(schema: Schema, parent: Int, mut leaves: List[Int]) raises:
    for child in range(parent + 1, len(schema)):
        var node = schema.node(child)
        if node.parent() == parent:
            if (
                node.kind() == SchemaNode.GROUP
                or node.kind() == SchemaNode.LIST
            ):
                _leaf_order(schema, child, leaves)
            else:
                leaves.append(child)


def _nested_footer(
    schema: Schema,
    leaves: List[Int],
    settings: List[NumericWriteOptions],
    chunks: List[_WrittenGroup],
    rows: Int,
    options: TableWriteOptions,
) raises -> List[UInt8]:
    var writer = CompactWriter(
        CompactLimits(max_bytes=options.max_metadata_bytes)
    )
    writer.begin_struct()
    _i32(writer, 1, 1)
    var nodes = len(schema)
    for i in range(1, len(schema)):
        nodes += Int(schema.node(i).kind() == SchemaNode.LIST)
    writer.write_field(2, CompactType.LIST)
    writer.write_collection(CompactType.STRUCT, nodes)
    _emit_nested_schema(writer, schema, 0)
    _i64(writer, 3, Int64(rows))
    var groups = len(chunks) // len(leaves)
    writer.write_field(4, CompactType.LIST)
    writer.write_collection(CompactType.STRUCT, groups)
    for g in range(groups):
        writer.begin_struct()
        writer.write_field(1, CompactType.LIST)
        writer.write_collection(CompactType.STRUCT, len(leaves))
        var raw = Int64(0)
        var stored = Int64(0)
        for c in range(len(leaves)):
            var chunk = chunks[g * len(leaves) + c]
            var field = _nested_field(
                schema.node(leaves[c]), settings[c].codec, False
            )
            var path = _ancestry(schema, leaves[c])
            var path_size = len(path)
            var has_levels = False
            for i in path:
                var node = schema.node(i)
                has_levels = (
                    has_levels
                    or node.nullable()
                    or node.kind() == SchemaNode.LIST
                )
                path_size += Int(node.kind() == SchemaNode.LIST)
            writer.begin_struct()
            _i64(writer, 2, 0)
            writer.write_field(3, CompactType.STRUCT)
            writer.begin_struct()
            _i32(writer, 1, field.physical)
            writer.write_field(2, CompactType.LIST)
            writer.write_collection(CompactType.I32, 2 if has_levels else 1)
            writer.write_i32(0)
            if has_levels:
                writer.write_i32(3)
            writer.write_field(3, CompactType.LIST)
            writer.write_collection(CompactType.BINARY, path_size)
            for i in path:
                var node = schema.node(i)
                writer.write_string(
                    "element" if schema.node(node.parent()).kind()
                    == SchemaNode.LIST else node.name()
                )
                if node.kind() == SchemaNode.LIST:
                    writer.write_string("list")
            _i32(writer, 4, field.codec)
            _i64(writer, 5, chunk.rows)  # level entries, not parent rows
            _i64(writer, 6, chunk.uncompressed_size)
            _i64(writer, 7, chunk.size)
            _i64(writer, 9, chunk.offset)
            writer.end_struct()
            writer.end_struct()
            if (
                chunk.uncompressed_size > Int64.MAX - raw
                or chunk.size > Int64.MAX - stored
            ):
                raise Error("Nested row-group size overflow")
            raw += chunk.uncompressed_size
            stored += chunk.size
        _i64(writer, 2, raw)
        _i64(
            writer,
            3,
            Int64(
                min(options.row_group_rows, rows - g * options.row_group_rows)
            ),
        )
        _i64(writer, 5, chunks[g * len(leaves)].offset)
        _i64(writer, 6, stored)
        writer.end_struct()
    _string(writer, 6, "pyroquet nested PLAIN writer")
    writer.end_struct()
    return writer^.finish()


def save_nested_table(
    path: String,
    table: NestedTable,
    options: TableWriteOptions = TableWriteOptions(),
    column_options: List[ColumnWriteOptions] = List[ColumnWriteOptions](),
) raises:
    """Borrow nested storage; publish atomically after complete footer emission.

    Column options follow logical primitive schema order. Canonical LIST physical
    element names are `element`. Row-aligned pages exceeding max_page_bytes fail;
    callers can lower page_rows, but a single oversized row cannot be staged.
    """
    var schema = table.schema()
    var columns = table.num_leaves()
    if (
        not columns
        or options.row_group_rows < 1
        or options.max_column_chunks < 0
    ):
        raise Error("Invalid nested writer shape/limits")
    if len(column_options) != 0 and len(column_options) != columns:
        raise Error("Nested column options must match leaf count")
    var groups = table.num_rows() // options.row_group_rows + Int(
        table.num_rows() % options.row_group_rows != 0
    )
    if groups > options.max_column_chunks // columns:
        raise Error("Output exceeds aggregate column-chunk limit")
    var leaves = List[Int]()
    _leaf_order(schema, 0, leaves)
    var indices = List[Int]()
    var settings = List[NumericWriteOptions]()
    for leaf in leaves:
        var index = 0
        for i in range(1, leaf):
            var kind = schema.node(i).kind()
            index += Int(kind != SchemaNode.GROUP and kind != SchemaNode.LIST)
        indices.append(index)
        var choice = ColumnWriteOptions()
        if len(column_options):
            choice = column_options[index]
        var setting = NumericWriteOptions(
            nullable=True,
            page_rows=choice.page_rows,
            page_version=choice.page_version,
            codec=choice.codec,
            max_page_bytes=choice.max_page_bytes,
            row_group_rows=options.row_group_rows,
            max_metadata_bytes=options.max_metadata_bytes,
            max_row_groups=options.max_row_groups,
        )
        setting.validate(0, table.num_rows(), 0)
        settings.append(setting)
    var chunks = List[_WrittenGroup](capacity=groups * columns)
    var file = NewFile(path)
    var magic: List[UInt8] = [80, 65, 82, 49]
    file.write_all(magic)
    var offset = Int64(4)
    var start = 0
    while start < table.num_rows():
        var count = min(options.row_group_rows, table.num_rows() - start)
        for c in range(columns):
            chunks.append(
                _nested_chunk(
                    file,
                    table,
                    schema,
                    leaves[c],
                    indices[c],
                    start,
                    count,
                    settings[c],
                    offset,
                )
            )
        start += count
    var footer = _nested_footer(
        schema, leaves, settings, chunks, table.num_rows(), options
    )
    if Int64(len(footer)) + 8 > Int64.MAX - offset:
        raise Error("Output file offset overflow")
    file.write_all(footer)
    var trailer = List[UInt8]()
    _append_u32(trailer, UInt32(len(footer)))
    for byte in magic:
        trailer.append(byte)
    file.write_all(trailer)
    file.finish()
