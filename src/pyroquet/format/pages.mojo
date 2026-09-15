"""Bounded plaintext PageHeader parsing and column-page inspection.

Page bodies are skipped, not decompressed or decoded. CRC is exposed but not
verified. V1 and V2 sizes exclude the serialized header. Unknown page types are
rejected until their corresponding header semantics are supported.
"""
from std.io.file import FileHandle
from compact_protocol import CompactReader, CompactLimits, CompactType
from .footer import _expect, _read_footer_bytes_from_file
from .metadata import (
    ColumnChunk,
    _seen,
    _i32,
    _nonnegative,
    _add,
    parse_metadata,
    validate_file_ranges,
)


struct PageLimits(ImplicitlyCopyable):
    var max_header_bytes: Int
    var max_page_bytes: Int
    var max_pages_per_chunk: Int

    def __init__(
        out self,
        max_header_bytes: Int = 65536,
        max_page_bytes: Int = 268435456,
        max_pages_per_chunk: Int = 100000,
    ):
        self.max_header_bytes = max_header_bytes
        self.max_page_bytes = max_page_bytes
        self.max_pages_per_chunk = max_pages_per_chunk

    def validate(self) raises:
        if (
            self.max_header_bytes <= 0
            or self.max_page_bytes < 0
            or self.max_pages_per_chunk < 0
        ):
            raise Error("Invalid page inspection limits")


struct PageHeader(ImplicitlyCopyable):
    var page_type: Int
    var uncompressed_page_size: Int
    var compressed_page_size: Int
    var header_size: Int
    var has_crc: Bool
    var crc: Int32
    var num_values: Int
    var encoding: Int
    var definition_level_encoding: Int
    var repetition_level_encoding: Int
    var num_nulls: Int
    var num_rows: Int
    var definition_levels_byte_length: Int
    var repetition_levels_byte_length: Int
    var is_compressed: Bool
    var has_is_sorted: Bool
    var is_sorted: Bool

    def __init__(out self):
        self.page_type = -1
        self.uncompressed_page_size = -1
        self.compressed_page_size = -1
        self.header_size = 0
        self.has_crc = False
        self.crc = 0
        self.num_values = -1
        self.encoding = -1
        self.definition_level_encoding = -1
        self.repetition_level_encoding = -1
        self.num_nulls = -1
        self.num_rows = -1
        self.definition_levels_byte_length = -1
        self.repetition_levels_byte_length = -1
        self.is_compressed = True
        self.has_is_sorted = False
        self.is_sorted = False


@fieldwise_init
struct PageLocation(ImplicitlyCopyable):
    var header: PageHeader
    var offset: Int64
    var payload_offset: Int64
    var next_offset: Int64


def _specific_header(mut r: CompactReader, kind: Int, mut h: PageHeader) raises:
    r.begin_struct()
    var seen = 0
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        _seen(seen, f, 8)
        if kind == 6:
            # IndexPageHeader is an empty struct in the current specification.
            r.skip_field(f)
        elif f.field_id == 1:
            h.num_values = Int(_nonnegative(r, f, False))
        elif kind == 8:
            if f.field_id == 2:
                h.num_nulls = Int(_nonnegative(r, f, False))
            elif f.field_id == 3:
                h.num_rows = Int(_nonnegative(r, f, False))
            elif f.field_id == 4:
                h.encoding = Int(_nonnegative(r, f, False))
            elif f.field_id == 5:
                h.definition_levels_byte_length = Int(_nonnegative(r, f, False))
            elif f.field_id == 6:
                h.repetition_levels_byte_length = Int(_nonnegative(r, f, False))
            elif f.field_id == 7:
                h.is_compressed = f.boolean()
            else:
                r.skip_field(f)
        elif f.field_id == 2:
            h.encoding = Int(_nonnegative(r, f, False))
        elif kind == 5 and f.field_id == 3:
            h.definition_level_encoding = Int(_nonnegative(r, f, False))
        elif kind == 5 and f.field_id == 4:
            h.repetition_level_encoding = Int(_nonnegative(r, f, False))
        elif kind == 7 and f.field_id == 3:
            h.is_sorted = f.boolean()
            h.has_is_sorted = True
        else:
            r.skip_field(f)
    r.end_struct()
    var required = 0
    if kind == 5:
        required = 30
    elif kind == 7:
        required = 6
    elif kind == 8:
        required = 126
    if (seen & required) != required:
        raise Error("Missing required page-specific header fields")


def parse_page_header(
    var bytes: List[UInt8], limits: PageLimits = PageLimits()
) raises -> PageHeader:
    """Parse one header prefix; header_size identifies the first payload byte.

    Trailing bytes are allowed because page headers have no length prefix.
    The provided lookahead buffer must fit max_header_bytes.
    """
    limits.validate()
    var compact_limits = CompactLimits(
        max_bytes=limits.max_header_bytes,
        max_binary_bytes=limits.max_header_bytes,
    )
    var r = CompactReader(bytes^, compact_limits)
    var h = PageHeader()
    var seen = 0
    var specific = -1
    r.begin_struct()
    while True:
        var f = r.next_field()
        if f.kind == CompactType.STOP:
            break
        _seen(seen, f, 8)
        if f.field_id == 1:
            h.page_type = _i32(r, f)
        elif f.field_id == 2:
            h.uncompressed_page_size = Int(_nonnegative(r, f, False))
        elif f.field_id == 3:
            h.compressed_page_size = Int(_nonnegative(r, f, False))
        elif f.field_id == 4:
            _expect(f, CompactType.I32)
            h.crc = r.read_i32()
            h.has_crc = True
        elif f.field_id >= 5 and f.field_id <= 8:
            if specific != -1:
                raise Error("Multiple page-specific headers")
            _expect(f, CompactType.STRUCT)
            specific = f.field_id
            _specific_header(r, specific, h)
        else:
            r.skip_field(f)
    r.end_struct()
    h.header_size = r.position()
    # Do not finish(): the lookahead may also contain payload or later pages.
    if (seen & 14) != 14:
        raise Error("Missing required PageHeader fields")
    if h.page_type < 0 or h.page_type > 3:
        raise Error("Unsupported Parquet page type")
    if specific != h.page_type + 5:
        raise Error("Page type disagrees with its specific header")
    if (
        h.compressed_page_size > limits.max_page_bytes
        or h.uncompressed_page_size > limits.max_page_bytes
    ):
        raise Error("Page size exceeds configured limit")
    if h.page_type == 0:
        if (
            h.definition_level_encoding != 3
            and h.definition_level_encoding != 4
        ) or (
            h.repetition_level_encoding != 3
            and h.repetition_level_encoding != 4
        ):
            raise Error("Invalid V1 level encoding")
    elif h.page_type == 3:
        h.definition_level_encoding = 3
        h.repetition_level_encoding = 3
        if h.num_nulls > h.num_values or h.num_rows > h.num_values:
            raise Error("Invalid V2 value/null/row counts")
        var levels = Int64(h.definition_levels_byte_length) + Int64(
            h.repetition_levels_byte_length
        )
        if levels > Int64(h.compressed_page_size) or levels > Int64(
            h.uncompressed_page_size
        ):
            raise Error("V2 levels exceed page payload")
        if (
            not h.is_compressed
            and h.compressed_page_size != h.uncompressed_page_size
        ):
            raise Error("Uncompressed V2 payload sizes disagree")
    return h


def read_page_header(
    mut file: FileHandle,
    offset: Int64,
    chunk_end: Int64,
    limits: PageLimits = PageLimits(),
) raises -> PageLocation:
    """Read bounded lookahead from an already validated plaintext chunk range.

    Reads at most max_header_bytes, possibly including some payload. Seeks to
    payload_offset on success. Caller must supply bounds validated for this file.
    """
    limits.validate()
    if offset < 4 or chunk_end <= offset or chunk_end > Int64(Int.MAX):
        raise Error("Invalid page/chunk range")
    var count = limits.max_header_bytes
    if Int64(count) > chunk_end - offset:
        count = Int(chunk_end - offset)
    _ = file.seek(Int(offset))
    var bytes = file.read_bytes(count)
    if len(bytes) != count:
        raise Error("Short page-header lookahead read")
    var header = parse_page_header(bytes^, limits)
    var payload = offset + Int64(header.header_size)
    if Int64(header.compressed_page_size) > chunk_end - payload:
        raise Error("Page payload exceeds column chunk")
    var end = payload + Int64(header.compressed_page_size)
    _ = file.seek(Int(payload))
    return PageLocation(header, offset, payload, end)


struct _ColumnPages(Movable):
    """Internal streaming cursor over an already validated column range.

    Drain next() through None to validate final totals. Discard on any error.
    """

    var col: ColumnChunk
    var offset: Int64
    var end: Int64
    var page_count: Int
    var values: Int64
    var uncompressed: Int64
    var first_data: Int64
    var dictionary: Int64
    var v2_rows: Int64
    var all_v2: Bool
    var num_rows: Int64
    var max_repetition: Int
    var limits: PageLimits

    def __init__(
        out self,
        var col: ColumnChunk,
        num_rows: Int64,
        max_repetition: Int,
        limits: PageLimits,
    ):
        self.offset = col.data_page_offset
        if col.dictionary_page_offset != -1:
            self.offset = col.dictionary_page_offset
        self.end = self.offset + col.total_compressed_size
        self.col = col^
        self.page_count = 0
        self.values = 0
        self.uncompressed = 0
        self.first_data = -1
        self.dictionary = -1
        self.v2_rows = 0
        self.all_v2 = True
        self.num_rows = num_rows
        self.max_repetition = max_repetition
        self.limits = limits

    def next(mut self, mut file: FileHandle) raises -> Optional[PageLocation]:
        if self.offset == self.end:
            self._finish()
            return None
        if self.page_count >= self.limits.max_pages_per_chunk:
            raise Error("Page count exceeds configured limit")
        var page = read_page_header(file, self.offset, self.end, self.limits)
        var h = page.header
        if h.page_type == 2:
            if self.page_count != 0 or self.dictionary != -1:
                raise Error(
                    "Dictionary must be the first and only dictionary page"
                )
            self.dictionary = self.offset
        elif h.page_type == 0 or h.page_type == 3:
            if self.first_data == -1:
                self.first_data = self.offset
            self.values = _add(self.values, Int64(h.num_values))
            if h.page_type == 0:
                self.all_v2 = False
            else:
                self.v2_rows = _add(self.v2_rows, Int64(h.num_rows))
                if self.max_repetition == 0 and h.num_rows != h.num_values:
                    raise Error("Non-repeated V2 row/value counts disagree")
        if (
            self.col.codec == 0
            and h.compressed_page_size != h.uncompressed_page_size
        ):
            raise Error("UNCOMPRESSED codec has inconsistent page sizes")
        self.uncompressed = _add(
            self.uncompressed,
            Int64(h.header_size) + Int64(h.uncompressed_page_size),
        )
        self.offset = page.next_offset
        self.page_count += 1
        return page

    def _finish(self) raises:
        if self.dictionary != self.col.dictionary_page_offset:
            raise Error("Dictionary page offset disagrees with footer")
        if (
            self.first_data != -1
            and self.first_data != self.col.data_page_offset
        ):
            raise Error("First data page offset disagrees with footer")
        if (
            self.values != self.col.num_values
            or self.uncompressed != self.col.total_uncompressed_size
        ):
            raise Error("Page totals disagree with column metadata")
        if self.all_v2 and self.v2_rows != self.num_rows:
            raise Error("V2 page row total disagrees with row group")


def inspect_column_pages(
    path: String,
    row_group: Int,
    column: Int,
    limits: PageLimits = PageLimits(),
    metadata_limits: CompactLimits = CompactLimits(),
) raises -> List[PageLocation]:
    """Inspect one column using one open file; skip bodies and check page totals.
    """
    limits.validate()
    var file = open(path, "r")
    var envelope = _read_footer_bytes_from_file(file, path, metadata_limits)
    var footer_offset = envelope.offset
    var metadata = parse_metadata(envelope^.take_bytes(), metadata_limits)
    validate_file_ranges(metadata, footer_offset)
    if row_group < 0 or row_group >= len(metadata.row_groups):
        raise Error("Row-group index out of range")
    if column < 0 or column >= len(metadata.row_groups[row_group].columns):
        raise Error("Column index out of range")
    var col = metadata.row_groups[row_group].columns[column].copy()
    var cursor = _ColumnPages(
        col^,
        metadata.row_groups[row_group].num_rows,
        metadata.schema[
            metadata.row_groups[row_group].columns[column].schema_index
        ].max_repetition_level,
        limits,
    )
    var pages = List[PageLocation]()
    while True:
        var next = cursor.next(file)
        if not next:
            break
        pages.append(next.value())
    return pages^
