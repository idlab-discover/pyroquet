"""Write a borrowed numeric column as bounded, uncompressed PLAIN V1/V2 pages."""
from std.memory import bitcast
from std.sys import size_of
from .io import NewFile
from .numojo_io import NumericColumn, _check_numeric
from .format.numeric_writer import _WrittenGroup, _plain_header, _numeric_footer


struct NumericWriteOptions(ImplicitlyCopyable):
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
    ):
        self.page_version = page_version
        self.nullable = nullable
        self.page_rows = page_rows
        self.row_group_rows = row_group_rows
        self.max_page_bytes = max_page_bytes
        self.max_metadata_bytes = max_metadata_bytes
        self.max_row_groups = max_row_groups

    def validate(self, physical_bytes: Int, rows: Int, nulls: Int) raises:
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


def _append_plain[dtype: DType](mut bytes: List[UInt8], value: Scalar[dtype]):
    _check_numeric[dtype]()
    comptime if size_of[Scalar[dtype]]() == 8:
        var bits = bitcast[DType.uint64](value)
        comptime for j in range(8):
            bytes.append(UInt8(bits >> UInt64(j * 8)))
    elif size_of[Scalar[dtype]]() == 4:
        _append_u32(bytes, bitcast[DType.uint32](value))
    elif dtype.is_signed():
        # Narrow signed physical INT32 values must be sign-extended.
        _append_u32(bytes, bitcast[DType.uint32](Int32(value)))
    else:
        _append_u32(bytes, UInt32(value))


def _numeric_page[
    dtype: DType
](
    column: NumericColumn[dtype],
    start: Int,
    count: Int,
    nullable: Bool,
    mut nulls: Int,
    page_version: Int = 1,
) raises -> List[UInt8]:
    if (
        start < 0
        or count < 1
        or start > column.size()
        or count > column.size() - start
    ):
        raise Error("Invalid numeric page range")
    var bytes = List[UInt8]()
    comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
    var level_bytes = 0
    var groups = count // 8 + Int(count % 8 != 0)
    var header = UInt32(groups * 2 + 1)
    var header_bytes = 1
    var remaining = header
    while remaining >= 128:
        header_bytes += 1
        remaining >>= 7
    if nullable:
        level_bytes = (4 if page_version == 1 else 0) + header_bytes + groups
    bytes.reserve(level_bytes + count * width)
    var validity = column.validity()
    if nullable:
        if page_version == 1:
            _append_u32(bytes, UInt32(header_bytes + groups))
        while header >= 128:
            bytes.append(UInt8(header & 127) | 128)
            header >>= 7
        bytes.append(UInt8(header))
        for group in range(groups):
            var packed = UInt8(0)
            for j in range(8):
                var index = group * 8 + j
                if index < count:
                    var row = start + index
                    if len(validity) == 0 or (
                        validity[row // 8] & (UInt8(1) << UInt8(row % 8))
                    ):
                        packed |= UInt8(1) << UInt8(j)
            bytes.append(packed)
    var values = column.values().unsafe_ptr()
    for i in range(count):
        var row = start + i
        if len(validity) == 0 or (
            validity[row // 8] & (UInt8(1) << UInt8(row % 8))
        ):
            _append_plain[dtype](bytes, values[unsafe_offset=row])
        else:
            nulls += 1
            if not nullable:
                raise Error("Required output cannot contain nulls")
    return bytes^


def save_numeric[
    dtype: DType
](
    path: String,
    column: NumericColumn[dtype],
    options: NumericWriteOptions = NumericWriteOptions(),
) raises:
    """Create a new single-column Parquet file from borrowed numeric storage.

    OPTIONAL output is the default; REQUIRED must be requested explicitly.
    Page buffers and footer bytes are bounded separately. The destination appears
    only after complete emission and close, and an existing path is never replaced.
    Publication requires same-filesystem hard links; crash durability is not promised.
    """
    _check_numeric[dtype]()
    comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
    options.validate(width, column.size(), column.null_count())
    var name = column.name()
    if name.byte_length() == 0:
        raise Error("Numeric output column name must be nonempty")
    var groups = List[_WrittenGroup]()
    var group_count = column.size() // options.row_group_rows + Int(
        column.size() % options.row_group_rows != 0
    )
    groups.reserve(group_count)
    var file = NewFile(path)
    var magic: List[UInt8] = [80, 65, 82, 49]
    file.write_all(magic)
    var offset = Int64(4)
    var start = 0
    while start < column.size():
        var count = min(options.row_group_rows, column.size() - start)
        var group_offset = offset
        var written = 0
        var nulls = 0
        while written < count:
            var page_rows = min(options.page_rows, count - written)
            var page_nulls = 0
            var bytes = _numeric_page[dtype](
                column,
                start + written,
                page_rows,
                options.nullable,
                page_nulls,
                options.page_version,
            )
            nulls += page_nulls
            # Present values occupy physical-width slots in both page formats.
            var level_bytes = len(bytes) - (page_rows - page_nulls) * width
            var header = _plain_header(
                page_rows,
                len(bytes),
                options.page_version,
                page_nulls,
                level_bytes,
            )
            var size = Int64(len(header)) + Int64(len(bytes))
            if size > Int64.MAX - offset:
                raise Error("Output file offset overflow")
            file.write_all(header)
            file.write_all(bytes)
            offset += size
            written += page_rows
        groups.append(
            _WrittenGroup(
                group_offset, offset - group_offset, Int64(count), Int64(nulls)
            )
        )
        start += count
    comptime physical = (4 if dtype == DType.float32 else 5) if (
        dtype == DType.float32 or dtype == DType.float64
    ) else (2 if width == 8 else 1)
    comptime integer_width = 0 if (
        dtype == DType.float32 or dtype == DType.float64
    ) else size_of[Scalar[dtype]]() * 8
    var footer = _numeric_footer(
        name,
        physical,
        integer_width,
        dtype.is_signed(),
        options.nullable,
        column.size(),
        groups,
        options.max_metadata_bytes,
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
