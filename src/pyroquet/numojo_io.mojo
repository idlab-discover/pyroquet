"""Direct-to-NuMojo flat numeric reading (PLAIN, dictionary and delta V1/V2).

NuMojo owns the sole decoded value allocation. Parquet contributes a packed
validity bitmap; null slots are initialized to zero, not a sentinel. Numeric
NuMojo operations do not automatically apply the bitmap.
"""
from .compression import validate_codec
from std.memory import bitcast, unsafe_memcpy
from std.sys.info import is_little_endian
from std.io.file import FileHandle
from std.sys import size_of
from numojo.core.ndarray import NDArray
from numojo.routines.creation import empty
from compact_protocol import CompactLimits
from .format.footer import _read_footer_bytes_from_file
from .format.metadata import (
    SchemaElement,
    FileMetadata,
    parse_metadata,
    validate_file_ranges,
)
from .format.pages import PageLimits, PageHeader, _ColumnPages
from .format.hybrid import _HybridDecoder
from .format.delta import _DeltaDecoder
from .format.flat_pages import _page_body, _flat_page_values, _u32


from .numeric_column import NumericColumn, _check_numeric


def _matches_numeric[dtype: DType](node: SchemaElement) -> Bool:
    _check_numeric[dtype]()
    comptime if dtype == DType.float16:
        return (
            node.physical_type == 7
            and node.type_length == 2
            and node.logical_type == 15
            and node.converted_type == -1
        )
    elif dtype == DType.float32 or dtype == DType.float64:
        return (
            node.physical_type == (4 if dtype == DType.float32 else 5)
            and node.logical_type == -1
            and node.converted_type == -1
        )
    else:
        return (
            node.physical_type == (2 if size_of[Scalar[dtype]]() == 8 else 1)
            and node.integer_width == size_of[Scalar[dtype]]() * 8
            and node.integer_signed == dtype.is_signed()
            and (
                node.logical_type == 10
                or (
                    node.logical_type == -1
                    and (
                        node.converted_type == -1
                        or 11 <= node.converted_type <= 18
                    )
                )
            )
        )


@always_inline
def _plain_value[
    dtype: DType
](bytes: List[UInt8], offset: Int) raises -> Scalar[dtype]:
    _check_numeric[dtype]()
    comptime width = 2 if dtype == DType.float16 else (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    )
    if offset < 0 or offset > len(bytes) or len(bytes) - offset < width:
        raise Error("Truncated numeric payload")
    comptime if dtype == DType.float16:
        return bitcast[dtype](
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        )
    elif width == 8:
        var bits = UInt64(0)
        comptime for j in range(8):
            bits |= UInt64(bytes[offset + j]) << UInt64(j * 8)
        return bitcast[dtype](bits)
    else:
        var bits = _u32(bytes, offset, len(bytes))
        comptime if size_of[Scalar[dtype]]() == 4:
            return bitcast[dtype](bits)
        elif dtype.is_signed():
            var signed = bitcast[DType.int32](bits)
            if signed < Int32(Scalar[dtype].MIN) or signed > Int32(
                Scalar[dtype].MAX
            ):
                raise Error("PLAIN integer outside declared narrow range")
            return signed.cast[dtype]()
        else:
            if bits > UInt32(Scalar[dtype].MAX):
                raise Error("PLAIN integer outside declared narrow range")
            return bits.cast[dtype]()


def _decode_plain_values[
    dtype: DType, origin: MutOrigin
](
    bytes: List[UInt8],
    start: Int,
    destination: Pointer[Scalar[dtype], origin],
    count: Int,
) raises:
    """Initialize count writable scalar slots; never read destination storage.

    The caller supplies at least count owner-tied writable slots that do not
    overlap bytes.
    Exact source bounds precede writes; narrowing failure may leave a partial
    result, which must not be published. Scalars require no destruction.
    """
    _check_numeric[dtype]()
    comptime width = 2 if dtype == DType.float16 else (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    )
    if (
        start < 0
        or start > len(bytes)
        or count < 0
        or count != (len(bytes) - start) // width
        or (len(bytes) - start) % width != 0
    ):
        raise Error("PLAIN byte length disagrees with value count")
    comptime if size_of[Scalar[dtype]]() >= 4 and is_little_endian():
        if count != 0:
            unsafe_memcpy(
                dest=destination.unsafe_bitcast[UInt8](),
                src=bytes.unsafe_ptr().unsafe_offset(start),
                count=count * width,
            )
    else:
        for i in range(count):
            destination.unsafe_offset(i).unsafe_write(
                _plain_value[dtype](bytes, start + i * width)
            )


def _gather_dictionary[
    dtype: DType, origin: MutOrigin
](
    bytes: List[UInt8],
    mut ids: _HybridDecoder,
    dictionary: List[Scalar[dtype]],
    destination: Span[Scalar[dtype], origin],
) raises:
    """Gather validated runs into an all-present, bounded destination."""
    var scratch = List[UInt32](length=64, fill=0)
    var output = 0
    var pointer = destination.unsafe_ptr()
    while output < len(destination):
        var batch = ids.next_batch(
            bytes, Span(scratch), len(destination) - output
        )
        var count = batch[0]
        if batch[1]:
            var index = scratch[0]
            if UInt64(index) >= UInt64(len(dictionary)):
                raise Error("Dictionary ID outside dictionary")
            var value = dictionary[Int(index)]
            var end = output + count
            while end - output >= 8:
                pointer.unsafe_offset(output).unsafe_store(
                    SIMD[dtype, 8](value)
                )
                output += 8
            while output < end:
                pointer[unsafe_offset=output] = value
                output += 1
        else:
            if (
                count <= 0
                or count > len(scratch)
                or count > len(destination) - output
            ):
                raise Error("Invalid packed dictionary batch count")
            # next_batch initialized [0, count); this borrow keeps scratch alive.
            var packed_ids = scratch.unsafe_ptr()
            for i in range(count):
                var index = packed_ids[unsafe_offset=i]
                if UInt64(index) >= UInt64(len(dictionary)):
                    raise Error("Dictionary ID outside dictionary")
                pointer[unsafe_offset=output + i] = dictionary[Int(index)]
            output += count
    ids.finish()


def _decode_numeric_page_impl[
    dtype: DType, indexed: Bool, origin: MutOrigin
](
    bytes: List[UInt8],
    h: PageHeader,
    nullable: Bool,
    values: Span[Scalar[dtype], origin],
    mut bitmap: List[UInt8],
    output: Int,
    dictionary: List[Scalar[dtype]],
    has_dictionary: Bool,
) raises -> Int:
    if h.encoding != 0 and not indexed:
        raise Error("Unsupported numeric data encoding")
    if indexed and not has_dictionary:
        raise Error("Dictionary data page has no dictionary")
    if (
        h.num_values < 0
        or output < 0
        or output > len(values)
        or h.num_values > len(values) - output
    ):
        raise Error("Page values exceed output allocation")
    var framing = _flat_page_values(bytes, h, nullable, bitmap, output)
    var data_start = framing[0]
    var present = framing[1]
    if not indexed and len(bytes) - data_start != present * (
        2 if dtype
        == DType.float16 else (8 if size_of[Scalar[dtype]]() == 8 else 4)
    ):
        raise Error("PLAIN byte length disagrees with non-null value count")
    var nulls = h.num_values - present
    # All-present is established by decoded levels, never footer statistics.
    comptime if not indexed:
        if nulls == 0:
            _decode_plain_values[dtype](
                bytes,
                data_start,
                values.unsafe_ptr().unsafe_offset(output),
                present,
            )
            return 0
    var ids = _HybridDecoder(0, 0, 0, 0)
    if indexed:
        if data_start >= len(bytes):
            raise Error("Missing dictionary ID bit width")
        ids = _HybridDecoder(
            data_start + 1, len(bytes), Int(bytes[data_start]), present
        )
    comptime if indexed:
        if nulls == 0:
            _gather_dictionary[dtype](
                bytes, ids, dictionary, values[output : output + present]
            )
            return 0
    var pointer = values.unsafe_ptr()
    var pos = data_start
    for i in range(h.num_values):
        var valid = True
        if nullable:
            valid = Bool(
                bitmap[(output + i) // 8]
                & (UInt8(1) << UInt8((output + i) % 8))
            )
        var value = Scalar[dtype](0)
        if valid:
            comptime if indexed:
                var index = ids.next(bytes)
                if UInt64(index) >= UInt64(len(dictionary)):
                    raise Error("Dictionary ID outside dictionary")
                value = dictionary[Int(index)]
            else:
                value = _plain_value[dtype](bytes, pos)
                pos += 2 if dtype == DType.float16 else (
                    8 if size_of[Scalar[dtype]]() == 8 else 4
                )
        pointer[unsafe_offset=output + i] = value
    if indexed:
        ids.finish()
    return nulls


def _delta_value[dtype: DType](bits: UInt64) raises -> Scalar[dtype]:
    """Apply the same physical-bit interpretation and narrowing as PLAIN."""
    comptime if size_of[Scalar[dtype]]() == 8:
        return bitcast[dtype](bits)
    elif size_of[Scalar[dtype]]() == 4:
        return bitcast[dtype](UInt32(bits))
    elif dtype.is_signed():
        var signed = bitcast[DType.int32](UInt32(bits))
        if signed < Int32(Scalar[dtype].MIN) or signed > Int32(
            Scalar[dtype].MAX
        ):
            raise Error("Delta integer outside declared narrow range")
        return signed.cast[dtype]()
    else:
        if bits > UInt64(Scalar[dtype].MAX):
            raise Error("Delta integer outside declared narrow range")
        return bits.cast[dtype]()


def _decode_delta_page[
    dtype: DType
](
    bytes: List[UInt8],
    h: PageHeader,
    nullable: Bool,
    mut values: NDArray[dtype],
    mut bitmap: List[UInt8],
    output: Int,
) raises -> Int:
    comptime if dtype == DType.float16 or dtype == DType.float32 or dtype == DType.float64:
        raise Error("DELTA_BINARY_PACKED requires physical INT32 or INT64")
    else:
        if (
            output < 0
            or output > values.size
            or h.num_values < 0
            or h.num_values > values.size - output
        ):
            raise Error("Delta page exceeds output allocation")
        var framing = _flat_page_values(bytes, h, nullable, bitmap, output)
        var decoder = _DeltaDecoder[
            64 if size_of[Scalar[dtype]]() == 8 else 32
        ](bytes, framing[0], len(bytes), framing[1])
        var pointer = values.unsafe_ptr()
        for i in range(h.num_values):
            var valid = True
            if nullable:
                valid = Bool(
                    bitmap[(output + i) // 8]
                    & (UInt8(1) << UInt8((output + i) % 8))
                )
            var value = Scalar[dtype](0)
            if valid:
                value = _delta_value[dtype](decoder.next(bytes))
            pointer[unsafe_offset=output + i] = value
        decoder.finish()
        return h.num_values - framing[1]


def _decode_numeric_page[
    dtype: DType
](
    bytes: List[UInt8],
    h: PageHeader,
    nullable: Bool,
    mut values: NDArray[dtype],
    mut bitmap: List[UInt8],
    output: Int,
    dictionary: List[Scalar[dtype]],
    has_dictionary: Bool,
) raises -> Int:
    if h.encoding == 5:
        return _decode_delta_page[dtype](
            bytes, h, nullable, values, bitmap, output
        )
    # Select once per page; PLAIN keeps its original encoding-free inner loop.
    if h.encoding == 2 or h.encoding == 8:
        return _decode_numeric_page_impl[dtype, True](
            bytes,
            h,
            nullable,
            Span(unsafe_ptr=values.unsafe_ptr(), length=values.size),
            bitmap,
            output,
            dictionary,
            has_dictionary,
        )
    return _decode_numeric_page_impl[dtype, False](
        bytes,
        h,
        nullable,
        Span(unsafe_ptr=values.unsafe_ptr(), length=values.size),
        bitmap,
        output,
        dictionary,
        has_dictionary,
    )


def _plain_dictionary[
    dtype: DType
](bytes: List[UInt8], count: Int) raises -> List[Scalar[dtype]]:
    """Validate byte length before allocation; return only initialized scalars.
    """
    _check_numeric[dtype]()
    comptime width = 2 if dtype == DType.float16 else (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    )
    if count < 0 or count != len(bytes) // width or len(bytes) % width != 0:
        raise Error("Dictionary byte length disagrees with entry count")
    # Length is deliberately uninitialized. No readable Span, growth, or
    # publication occurs until the write-only transfer succeeds.
    var entries = List[Scalar[dtype]](unsafe_uninit_length=count)
    _decode_plain_values[dtype](bytes, 0, entries.unsafe_ptr(), count)
    return entries^


def _check_dictionary_header[dtype: DType](h: PageHeader, limit: Int) raises:
    # Validate cardinality against physical bytes before decompression/allocation.
    comptime width = 2 if dtype == DType.float16 else (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    )
    if h.encoding != 0 and h.encoding != 2:
        raise Error("Dictionary entries require PLAIN encoding")
    if h.num_values < 0 or h.num_values > limit // width:
        raise Error("Dictionary cardinality exceeds page budget")
    if h.uncompressed_page_size != h.num_values * width:
        raise Error("Dictionary byte length disagrees with entry count")


def load_numeric[
    dtype: DType
](
    path: String,
    column_name: String,
    max_output_bytes: Int = 1073741824,
    page_limits: PageLimits = PageLimits(),
    metadata_limits: CompactLimits = CompactLimits(),
) raises -> NumericColumn[dtype]:
    """Load a named top-level numeric column across all row groups into NuMojo.

    One decoded allocation; bounded page-body buffers. The output budget covers
    values plus validity, not metadata, page buffers or codec workspace. Codecs
    other than UNCOMPRESSED/SNAPPY/GZIP, nested, encrypted and mismatched numeric
    columns are unsupported. Parquet page CRC is not verified; GZIP integrity
    checks are enforced. Never returns partially filled data.
    """
    _check_numeric[dtype]()
    if max_output_bytes < 0:
        raise Error("Negative output budget")
    page_limits.validate()
    var file = open(path, "r")
    var envelope = _read_footer_bytes_from_file(file, path, metadata_limits)
    var footer_offset = envelope.offset
    var metadata = parse_metadata(envelope^.take_bytes(), metadata_limits)
    validate_file_ranges(metadata, footer_offset)
    var selected = -1
    var column_index = -1
    var leaf_index = 0
    for i in range(1, len(metadata.schema)):
        if metadata.schema[i].is_group():
            continue
        if (
            metadata.schema[i].parent == 0
            and metadata.schema[i].name == column_name
        ):
            selected = i
            column_index = leaf_index
        leaf_index += 1
    if selected == -1:
        raise Error("Top-level column not found: " + column_name)
    return _load_numeric_from_file[dtype](
        file, metadata, selected, column_index, max_output_bytes, page_limits
    )


def _load_numeric_from_file[
    dtype: DType
](
    mut file: FileHandle,
    metadata: FileMetadata,
    selected: Int,
    column_index: Int,
    max_output_bytes: Int,
    page_limits: PageLimits,
) raises -> NumericColumn[dtype]:
    """Decode one selected leaf using already validated metadata and open file.
    """
    var node = metadata.schema[selected].copy()
    if not _matches_numeric[dtype](node) or node.max_repetition_level != 0:
        raise Error(
            "Expected a flat required/optional column matching requested dtype"
        )
    var nullable = node.nullable()
    var rows64 = metadata.num_rows
    if rows64 > Int64(max_output_bytes // size_of[Scalar[dtype]]()):
        raise Error("Column exceeds output budget")
    var rows = Int(rows64)
    var bitmap_bytes = 0
    if nullable:
        bitmap_bytes = rows // 8 + Int(rows % 8 != 0)
    if bitmap_bytes > max_output_bytes - rows * size_of[Scalar[dtype]]():
        raise Error("Column validity exceeds output budget")
    for group in metadata.row_groups:
        validate_codec(group.columns[column_index].codec)
    var values = empty[dtype]([rows])
    var validity = List[UInt8]()
    validity.reserve(bitmap_bytes)
    for _ in range(bitmap_bytes):
        validity.append(0)
    var output = 0
    var null_count = 0
    for group in metadata.row_groups:
        var dictionary = List[Scalar[dtype]]()
        var has_dictionary = False
        var cursor = _ColumnPages(
            group.columns[column_index].copy(), group.num_rows, 0, page_limits
        )
        while True:
            var next = cursor.next(file)
            if not next:
                break
            var page = next.value()
            if page.header.page_type == 2:
                _check_dictionary_header[dtype](
                    page.header, page_limits.max_page_bytes
                )
            elif page.header.page_type != 0 and page.header.page_type != 3:
                raise Error("Unsupported numeric page type")
            var bytes = file.read_bytes(page.header.compressed_page_size)
            if len(bytes) != page.header.compressed_page_size:
                raise Error("Short data-page payload read")
            bytes = _page_body(
                bytes^, page.header, group.columns[column_index].codec
            )
            if page.header.page_type == 2:
                dictionary = _plain_dictionary[dtype](
                    bytes, page.header.num_values
                )
                has_dictionary = True
                continue
            null_count += _decode_numeric_page[dtype](
                bytes,
                page.header,
                nullable,
                values,
                validity,
                output,
                dictionary,
                has_dictionary,
            )
            output += page.header.num_values
    if output != rows:
        raise Error("Decoded row count disagrees with footer")
    if null_count == 0:
        validity = List[UInt8]()
    return NumericColumn[dtype](values^, validity^, node.name, null_count)
