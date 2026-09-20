"""Write a borrowed numeric column as bounded PLAIN V1/V2 pages."""
from std.memory import bitcast
from std.sys import size_of
from .io import NewFile
from .numeric_column import NumericColumn, _check_numeric
from .format.flat_writer import _WrittenGroup, _numeric_footer
from .format.page_write import NumericWriteOptions, _append_u32, _write_page


def _append_plain[dtype: DType](mut bytes: List[UInt8], value: Scalar[dtype]):
    _check_numeric[dtype]()
    comptime if dtype == DType.float16:
        var bits = bitcast[DType.uint16](value)
        bytes.append(UInt8(bits))
        bytes.append(UInt8(bits >> 8))
    elif size_of[Scalar[dtype]]() == 8:
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
    comptime width = 2 if dtype == DType.float16 else (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    )
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


def _write_numeric_chunk[
    dtype: DType
](
    mut file: NewFile,
    column: NumericColumn[dtype],
    start: Int,
    count: Int,
    options: NumericWriteOptions,
    mut offset: Int64,
) raises -> _WrittenGroup:
    """Emit one borrowed row range, retaining only bounded page staging."""
    comptime width = 2 if dtype == DType.float16 else (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    )
    var group_offset = offset
    var written = 0
    var nulls = 0
    var uncompressed_size = Int64(0)
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
        var raw_size = _write_page(
            file, bytes^, page_rows, page_nulls, level_bytes, options, offset
        )
        if raw_size > Int64.MAX - uncompressed_size:
            raise Error("Uncompressed row-group size overflow")
        uncompressed_size += raw_size
        written += page_rows
    return _WrittenGroup(
        group_offset,
        offset - group_offset,
        uncompressed_size,
        Int64(count),
        Int64(nulls),
    )


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
    comptime width = 2 if dtype == DType.float16 else (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    )
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
        groups.append(
            _write_numeric_chunk[dtype](
                file, column, start, count, options, offset
            )
        )
        start += count
    comptime physical = (
        7 if dtype == DType.float16 else (4 if dtype == DType.float32 else 5)
    ) if (
        dtype == DType.float16
        or dtype == DType.float32
        or dtype == DType.float64
    ) else (
        2 if width == 8 else 1
    )
    comptime integer_width = 0 if (
        dtype == DType.float16
        or dtype == DType.float32
        or dtype == DType.float64
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
        options.codec,
        dtype == DType.float16,
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
