"""Bounded physical page emission shared by numeric and binary writers.

NumericWriteOptions keeps its established public name and import path; its
implementation here depends only on physical page framing, never column storage.
"""
from ..io import NewFile
from .flat_writer import _plain_header
from ..compression import compress, validate_codec


struct NumericWriteOptions(ImplicitlyCopyable):
    """Codec 0 is uncompressed (default); 1 is native Snappy; 2 is GZIP; 6 is ZSTD.

    max_page_bytes bounds each raw and stored page body separately. Codec
    staging additionally uses a bounded encoded buffer and encoder workspace.
    """

    var codec: Int
    var page_version: Int
    var nullable: Bool
    var page_rows: Int
    var row_group_rows: Int
    var max_page_bytes: Int
    var max_metadata_bytes: Int
    var max_row_groups: Int

    def __init__(
        out self,
        nullable: Bool = True,
        page_rows: Int = 65536,
        row_group_rows: Int = 1048576,
        max_page_bytes: Int = 1048576,
        max_metadata_bytes: Int = 67108864,
        max_row_groups: Int = 100000,
        page_version: Int = 1,
        codec: Int = 0,
    ):
        self.codec = codec
        self.page_version = page_version
        self.nullable = nullable
        self.page_rows = page_rows
        self.row_group_rows = row_group_rows
        self.max_page_bytes = max_page_bytes
        self.max_metadata_bytes = max_metadata_bytes
        self.max_row_groups = max_row_groups

    def validate(self, physical_bytes: Int, rows: Int, nulls: Int) raises:
        validate_codec(self.codec)
        if (
            (self.page_version != 1 and self.page_version != 2)
            or self.page_rows < 1
            or self.page_rows > 2147483647
            or self.row_group_rows < 1
            or self.max_page_bytes < 1
            or self.max_page_bytes > 2147483647
            or self.max_metadata_bytes < 1
            or self.max_metadata_bytes > 2147483647
            or self.max_row_groups < 0
            or self.max_row_groups > 1000000
        ):
            raise Error("Invalid numeric write options")
        if not self.nullable and nulls != 0:
            raise Error("Required output cannot contain nulls")
        var count = rows // self.row_group_rows + Int(
            rows % self.row_group_rows != 0
        )
        if count > self.max_row_groups:
            raise Error("Output exceeds row-group limit")
        var page_count = min(self.page_rows, min(self.row_group_rows, rows))
        var bound = page_count * physical_bytes
        if self.nullable and page_count != 0:
            # V1 alone has a four-byte prefix; both have a hybrid header.
            bound += (4 if self.page_version == 1 else 0) + 5
            bound += page_count // 8 + Int(page_count % 8 != 0)
        if bound > self.max_page_bytes:
            raise Error("Configured page rows exceed page byte limit")


def _append_u32(mut bytes: List[UInt8], value: UInt32):
    comptime for j in range(4):
        bytes.append(UInt8(value >> UInt32(j * 8)))


def _write_page(
    mut file: NewFile,
    var bytes: List[UInt8],
    page_rows: Int,
    page_nulls: Int,
    level_bytes: Int,
    options: NumericWriteOptions,
    mut offset: Int64,
    num_rows: Int = -1,
    repetition_bytes: Int = 0,
) raises -> Int64:
    """Emit one physical PLAIN page with shared V1/V2 compression framing."""
    var body_size = len(bytes)
    var compressed = List[UInt8]()
    var is_compressed = False
    if options.codec != 0:
        if options.page_version == 1:
            compressed = compress(options.codec, bytes, options.max_page_bytes)
            is_compressed = True
        else:
            var values_size = body_size - level_bytes
            # Permit expansion within a bounded temporary buffer, then
            # retain raw values when compression does not save space.
            compressed = compress(
                options.codec,
                bytes,
                options.max_page_bytes,
                level_bytes,
                allow_expansion=True,
            )
            is_compressed = len(compressed) < values_size
    var stored_size = body_size
    if is_compressed:
        stored_size = len(compressed)
        if options.page_version == 2:
            stored_size += level_bytes
    if stored_size > options.max_page_bytes:
        raise Error("Stored page exceeds page byte limit")
    var header = _plain_header(
        page_rows,
        body_size,
        options.page_version,
        page_nulls,
        level_bytes - repetition_bytes,
        stored_size,
        is_compressed,
        num_rows,
        repetition_bytes,
    )
    var size = Int64(len(header)) + Int64(stored_size)
    if size > Int64.MAX - offset:
        raise Error("Output file offset overflow")
    file.write_all(header)
    if is_compressed:
        if options.page_version == 2 and level_bytes != 0:
            var levels = List[UInt8](capacity=level_bytes)
            for i in range(level_bytes):
                levels.append(bytes[i])
            file.write_all(levels)
        file.write_all(compressed)
    else:
        file.write_all(bytes)
    var raw_size = Int64(len(header)) + Int64(body_size)
    offset += size
    return raw_size
