"""Direct-to-NuMojo flat numeric reading (uncompressed/Snappy PLAIN and dictionary V1/V2).

NuMojo owns the sole decoded value allocation. Parquet contributes a packed
validity bitmap; null slots are initialized to zero, not a sentinel. Numeric
NuMojo operations do not automatically apply the bitmap.
"""
from std.memory import bitcast
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
from .format.flat_pages import _page_body, _flat_page_values, _u32


from .numeric_column import NumericColumn, NumojoUInt32Column, _check_numeric


def _matches_numeric[dtype: DType](node: SchemaElement) -> Bool:
    _check_numeric[dtype]()
    comptime if dtype == DType.float32 or dtype == DType.float64:
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
    comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
    if offset < 0 or offset > len(bytes) or len(bytes) - offset < width:
        raise Error("Truncated numeric payload")
    comptime if width == 8:
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


def _decode_numeric_page_impl[
    dtype: DType, indexed: Bool
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
    if h.encoding != 0 and not indexed:
        raise Error("Unsupported numeric data encoding")
    if indexed and not has_dictionary:
        raise Error("Dictionary data page has no dictionary")
    if (
        h.num_values < 0
        or output < 0
        or output > values.size
        or h.num_values > values.size - output
    ):
        raise Error("Page values exceed output allocation")
    var framing = _flat_page_values(bytes, h, nullable, bitmap, output)
    var data_start = framing[0]
    var present = framing[1]
    if not indexed and len(bytes) - data_start != present * (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    ):
        raise Error("PLAIN byte length disagrees with non-null value count")
    var nulls = h.num_values - present
    var ids = _HybridDecoder(0, 0, 0, 0)
    if indexed:
        if data_start >= len(bytes):
            raise Error("Missing dictionary ID bit width")
        ids = _HybridDecoder(
            data_start + 1, len(bytes), Int(bytes[data_start]), present
        )
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
                pos += 8 if size_of[Scalar[dtype]]() == 8 else 4
        pointer[unsafe_offset=output + i] = value
    if indexed:
        ids.finish()
    return nulls


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
    # Select once per page; PLAIN keeps its original encoding-free inner loop.
    if h.encoding == 2 or h.encoding == 8:
        return _decode_numeric_page_impl[dtype, True](
            bytes,
            h,
            nullable,
            values,
            bitmap,
            output,
            dictionary,
            has_dictionary,
        )
    return _decode_numeric_page_impl[dtype, False](
        bytes, h, nullable, values, bitmap, output, dictionary, has_dictionary
    )


def _decode_plain_page[
    dtype: DType
](
    bytes: List[UInt8],
    h: PageHeader,
    nullable: Bool,
    mut values: NDArray[dtype],
    mut bitmap: List[UInt8],
    output: Int,
) raises -> Int:
    """PLAIN-only internal compatibility seam used by native tests."""
    if h.encoding != 0:
        raise Error("Expected PLAIN numeric encoding")
    var dictionary = List[Scalar[dtype]]()
    return _decode_numeric_page[dtype](
        bytes, h, nullable, values, bitmap, output, dictionary, False
    )


def _check_dictionary_header[dtype: DType](h: PageHeader, limit: Int) raises:
    # Validate cardinality against physical bytes before decompression/allocation.
    comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
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
    values plus validity, not metadata or page buffers. Non-Snappy codecs,
    nested, encrypted and mismatched numeric columns are explicitly unsupported.
    CRC verification is not yet implemented. Never returns partially filled data.
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
        if (
            group.columns[column_index].codec != 0
            and group.columns[column_index].codec != 1
        ):
            raise Error("Only UNCOMPRESSED and SNAPPY columns are supported")
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
                dictionary.reserve(page.header.num_values)
                for i in range(page.header.num_values):
                    dictionary.append(
                        _plain_value[dtype](
                            bytes,
                            i * (8 if size_of[Scalar[dtype]]() == 8 else 4),
                        )
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


def load_uint32(
    path: String,
    column_name: String,
    max_output_bytes: Int = 1073741824,
    page_limits: PageLimits = PageLimits(),
    metadata_limits: CompactLimits = CompactLimits(),
) raises -> NumojoUInt32Column:
    """Compatibility shorthand for load_numeric[DType.uint32]."""
    return load_numeric[DType.uint32](
        path, column_name, max_output_bytes, page_limits, metadata_limits
    )
