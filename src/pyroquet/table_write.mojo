"""Transactional flat mixed scalar writing with independent column pages."""
from std.sys import size_of
from .table import Table
from .schema import SchemaNode
from .binary_write import _write_binary_chunk
from .io import NewFile
from .numojo_write import NumericWriteOptions, _write_numeric_chunk, _append_u32
from .format.numeric_writer import _WrittenField, _WrittenGroup, _table_footer


struct ColumnWriteOptions(ImplicitlyCopyable):
    """Per-column PLAIN encoding, page boundaries, codec and staging bound."""

    var page_rows: Int
    var page_version: Int
    var codec: Int
    var max_page_bytes: Int

    def __init__(
        out self,
        page_rows: Int = 65536,
        page_version: Int = 1,
        codec: Int = 0,
        max_page_bytes: Int = 1048576,
    ):
        self.page_rows = page_rows
        self.page_version = page_version
        self.codec = codec
        self.max_page_bytes = max_page_bytes


struct TableWriteOptions(ImplicitlyCopyable):
    """Shared row groups and aggregate retained footer/chunk limits."""

    var row_group_rows: Int
    var max_metadata_bytes: Int
    var max_row_groups: Int
    var max_column_chunks: Int

    def __init__(
        out self,
        row_group_rows: Int = 1048576,
        max_metadata_bytes: Int = 67108864,
        max_row_groups: Int = 100000,
        max_column_chunks: Int = 1000000,
    ):
        self.row_group_rows = row_group_rows
        self.max_metadata_bytes = max_metadata_bytes
        self.max_row_groups = max_row_groups
        self.max_column_chunks = max_column_chunks


def save_table(
    path: String,
    table: Table,
    options: TableWriteOptions = TableWriteOptions(),
    column_options: List[ColumnWriteOptions] = List[ColumnWriteOptions](),
) raises:
    """Borrow all columns and publish a complete new file after footer emission.

    Schema nullability is authoritative. Per-column options follow schema order.
    Zero-row tables retain schema; writing zero-column tables is unsupported.
    One page is staged at a time; chunk metadata is bounded across all columns.
    """
    var columns = table.num_columns()
    var rows = table.num_rows()
    if columns == 0:
        raise Error("Writing zero-column tables is unsupported")
    if len(column_options) != 0 and len(column_options) != columns:
        raise Error("Column options must match table column count")
    if options.row_group_rows < 1 or options.max_column_chunks < 0:
        raise Error("Invalid table write limits")
    var group_count = rows // options.row_group_rows + Int(
        rows % options.row_group_rows != 0
    )
    if group_count > options.max_column_chunks // columns:
        raise Error("Output exceeds aggregate column-chunk limit")
    var schema = table.schema()
    var fields = List[_WrittenField](capacity=columns)
    var configured = List[NumericWriteOptions](capacity=columns)
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
    for c in range(columns):
        var setting = ColumnWriteOptions()
        if len(column_options) != 0:
            setting = column_options[c]
        var node = schema.node(c + 1)
        var numeric_options = NumericWriteOptions(
            nullable=node.nullable(),
            page_rows=setting.page_rows,
            row_group_rows=options.row_group_rows,
            max_page_bytes=setting.max_page_bytes,
            max_metadata_bytes=options.max_metadata_bytes,
            max_row_groups=options.max_row_groups,
            page_version=setting.page_version,
            codec=setting.codec,
        )
        var name = node.name()
        if name.byte_length() == 0:
            raise Error("Output column name must be nonempty")
        comptime for t in range(10):
            comptime dtype = types[t]
            if table.column(c).kind() == SchemaNode.numeric_kind[dtype]():
                comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
                numeric_options.validate(
                    width, rows, table.column(c).null_count()
                )
                comptime floating = dtype == DType.float32 or dtype == DType.float64
                comptime physical = (
                    4 if dtype == DType.float32 else 5
                ) if floating else (2 if width == 8 else 1)
                comptime integer_width = 0 if floating else size_of[
                    Scalar[dtype]
                ]() * 8
                fields.append(
                    _WrittenField(
                        name.copy(),
                        physical,
                        integer_width,
                        dtype.is_signed(),
                        node.nullable(),
                        setting.codec,
                        0,
                    )
                )
        if node.kind() >= SchemaNode.BOOLEAN:
            numeric_options.validate(0, rows, table.column(c).null_count())
            var physical = 0 if node.kind() == SchemaNode.BOOLEAN else (
                7 if node.kind() == SchemaNode.FIXED_BINARY else 6
            )
            fields.append(
                _WrittenField(
                    name.copy(),
                    physical,
                    0,
                    False,
                    node.nullable(),
                    setting.codec,
                    node.fixed_width(),
                )
            )
        configured.append(numeric_options)
    var chunks = List[_WrittenGroup](capacity=group_count * columns)
    var file = NewFile(path)
    var magic: List[UInt8] = [80, 65, 82, 49]
    file.write_all(magic)
    var offset = Int64(4)
    var start = 0
    while start < rows:
        var count = min(options.row_group_rows, rows - start)
        for c in range(columns):
            if table.column(c).kind() >= SchemaNode.BOOLEAN:
                chunks.append(
                    _write_binary_chunk(
                        file,
                        table.column(c),
                        start,
                        count,
                        configured[c],
                        offset,
                    )
                )
                continue
            comptime for t in range(10):
                comptime dtype = types[t]
                if table.column(c).kind() == SchemaNode.numeric_kind[dtype]():
                    chunks.append(
                        _write_numeric_chunk[dtype](
                            file,
                            table.column(c).numeric[dtype](),
                            start,
                            count,
                            configured[c],
                            offset,
                        )
                    )
        start += count
    var footer = _table_footer(
        fields, rows, chunks, group_count, options.max_metadata_bytes
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
