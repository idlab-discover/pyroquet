"""Direct-to-NuMojo flat numeric reading (uncompressed PLAIN V1/V2 only).

NuMojo owns the sole decoded value allocation. Parquet contributes a packed
validity bitmap; null slots are initialized to zero, not a sentinel. Numeric
NuMojo operations do not automatically apply the bitmap.
"""
from std.memory import bitcast
from std.sys import size_of
from numojo.core.ndarray import NDArray
from numojo.routines.creation import empty
from compact_protocol import CompactLimits
from .format.footer import _read_footer_bytes_from_file
from .format.metadata import SchemaElement, parse_metadata, validate_file_ranges
from .format.pages import PageLimits, PageHeader, _ColumnPages


struct NumericColumn[dtype: DType](Movable):
    var _values: NDArray[Self.dtype]
    var _validity: List[UInt8]
    var _name: String
    var _null_count: Int

    def __init__(
        out self,
        var values: NDArray[Self.dtype],
        var validity: List[UInt8],
        var name: String,
        null_count: Int,
    ) raises:
        _check_numeric[Self.dtype]()
        if values.ndim != 1 or null_count < 0 or null_count > values.size:
            raise Error("Invalid numeric column shape/count")
        if values.strides[0] != 1:
            raise Error(
                "Numeric column requires contiguous unit-stride storage"
            )
        if len(validity) == 0:
            if null_count != 0:
                raise Error("Nulls require a validity bitmap")
        else:
            if len(validity) != values.size // 8 + Int(values.size % 8 != 0):
                raise Error("Invalid column validity length")
            var present = 0
            for byte in validity:
                for bit in range(8):
                    present += Int((byte >> UInt8(bit)) & 1)
            if values.size % 8 != 0:
                if (validity[len(validity) - 1] >> UInt8(values.size % 8)) != 0:
                    raise Error("Nonzero validity padding")
            if values.size - present != null_count:
                raise Error("Validity and null count disagree")
        self._values = values^
        self._validity = validity^
        self._name = name^
        self._null_count = null_count

    def values(self) -> ref[origin_of(self._values)] NDArray[Self.dtype]:
        """Borrow numeric storage read-only; consult validity for nulls."""
        return self._values

    def validity(self) -> Span[UInt8, origin_of(self._validity)]:
        """LSB-first packed validity; empty means all valid."""
        return Span(self._validity)

    def name(self) -> String:
        return self._name

    def size(self) -> Int:
        return self._values.size

    def null_count(self) -> Int:
        return self._null_count

    def value(self, index: Int) raises -> Optional[Scalar[Self.dtype]]:
        if index < 0 or index >= self.size():
            raise Error("Column index out of range")
        if len(self._validity) != 0 and not (
            self._validity[index // 8] & (UInt8(1) << UInt8(index % 8))
        ):
            return None
        return self._values.unsafe_ptr()[unsafe_offset=index]


# Compatibility names share the parameterized implementation.
comptime NumojoUInt32Column = NumericColumn[DType.uint32]


def _check_numeric[dtype: DType]():
    comptime assert (
        dtype == DType.int8
        or dtype == DType.uint8
        or dtype == DType.int16
        or dtype == DType.uint16
        or dtype == DType.int32
        or dtype == DType.uint32
        or dtype == DType.int64
        or dtype == DType.uint64
        or dtype == DType.float32
        or dtype == DType.float64
    ), "Unsupported numeric dtype"


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


def _u32(bytes: List[UInt8], offset: Int, end: Int) raises -> UInt32:
    if offset < 0 or offset > end or end > len(bytes) or end - offset < 4:
        raise Error("Truncated UInt32 payload")
    var value = UInt32(0)
    for j in range(4):
        value |= UInt32(bytes[offset + j]) << UInt32(j * 8)
    return value


def _set_valid(mut bitmap: List[UInt8], index: Int):
    bitmap[index // 8] |= UInt8(1) << UInt8(index % 8)


def _definition_levels(
    bytes: List[UInt8],
    start: Int,
    end: Int,
    count: Int,
    mut bitmap: List[UInt8],
    output: Int,
) raises -> Int:
    """Decode one-bit RLE/bit-packed hybrid directly into final validity."""
    var pos = start
    var written = 0
    var present = 0
    while written < count:
        var header = UInt32(0)
        var terminated = False
        for j in range(5):
            if pos >= end:
                raise Error("Truncated definition-level run")
            var byte = bytes[pos]
            pos += 1
            if j == 4 and byte > 15:
                raise Error("Definition-level varint overflow")
            header |= UInt32(byte & 127) << UInt32(j * 7)
            if (byte & 128) == 0:
                terminated = True
                break
        if not terminated:
            raise Error("Definition-level varint overflow")
        var run = Int(header >> 1)
        if run == 0:
            raise Error("Zero-length definition-level run")
        if (header & 1) == 0:
            if run > count - written or pos >= end:
                raise Error("Definition-level RLE run exceeds page")
            var value = bytes[pos]
            pos += 1
            if value > 1:
                raise Error("Invalid flat definition level")
            if value == 1:
                for i in range(run):
                    _set_valid(bitmap, output + written + i)
                present += run
            written += run
        else:
            # Each group contains eight one-bit levels in one byte.
            if run > 2147483647 // 8 or run > end - pos:
                raise Error("Truncated or oversized bit-packed levels")
            var total = run * 8
            var used = total
            if used > count - written:
                used = count - written
                if total - used > 7:
                    raise Error("Excess bit-packed definition levels")
            for i in range(used):
                if (bytes[pos + i // 8] >> UInt8(i % 8)) & 1:
                    _set_valid(bitmap, output + written + i)
                    present += 1
            pos += run
            written += used
    if pos != end:
        raise Error("Trailing definition-level bytes")
    return present


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
    if h.encoding != 0:
        raise Error("Only PLAIN numeric encoding is supported")
    if (
        h.num_values < 0
        or output < 0
        or output > values.size
        or h.num_values > values.size - output
    ):
        raise Error("Page values exceed output allocation")
    var data_start = 0
    var level_start = 0
    var level_end = 0
    if h.page_type == 0:
        if nullable:
            if h.definition_level_encoding != 3:
                raise Error(
                    "Only RLE/hybrid V1 definition levels are supported"
                )
            var length = Int(_u32(bytes, 0, len(bytes)))
            level_start = 4
            if length > len(bytes) - 4:
                raise Error("V1 definition levels exceed payload")
            level_end = 4 + length
            data_start = level_end
    elif h.page_type == 3:
        if h.repetition_levels_byte_length != 0:
            raise Error("Flat columns cannot have repetition-level bytes")
        level_end = h.definition_levels_byte_length
        if level_end > len(bytes) or (not nullable and level_end != 0):
            raise Error("Invalid V2 definition-level length")
        data_start = level_end
    else:
        raise Error("Expected a data page")
    var present = h.num_values
    if nullable:
        present = _definition_levels(
            bytes, level_start, level_end, h.num_values, bitmap, output
        )
    if len(bytes) - data_start != present * (
        8 if size_of[Scalar[dtype]]() == 8 else 4
    ):
        raise Error("PLAIN byte length disagrees with non-null value count")
    var nulls = h.num_values - present
    if h.page_type == 3 and h.num_nulls != nulls:
        raise Error("V2 null count disagrees with definition levels")
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
            value = _plain_value[dtype](bytes, pos)
            pos += 8 if size_of[Scalar[dtype]]() == 8 else 4
        pointer[unsafe_offset=output + i] = value
    return nulls


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
    values plus validity, not metadata or page buffers. Compressed, dictionary,
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
        if group.columns[column_index].codec != 0:
            raise Error("Only UNCOMPRESSED columns are supported")
        if group.columns[column_index].dictionary_page_offset != -1:
            raise Error("Dictionary columns are not supported yet")
    var values = empty[dtype]([rows])
    var validity = List[UInt8]()
    validity.reserve(bitmap_bytes)
    for _ in range(bitmap_bytes):
        validity.append(0)
    var output = 0
    var null_count = 0
    for group in metadata.row_groups:
        var cursor = _ColumnPages(
            group.columns[column_index].copy(), group.num_rows, 0, page_limits
        )
        while True:
            var next = cursor.next(file)
            if not next:
                break
            var page = next.value()
            if page.header.page_type != 0 and page.header.page_type != 3:
                raise Error(
                    "Only data pages are supported by the numeric loader"
                )
            var bytes = file.read_bytes(page.header.compressed_page_size)
            if len(bytes) != page.header.compressed_page_size:
                raise Error("Short data-page payload read")
            null_count += _decode_plain_page[dtype](
                bytes, page.header, nullable, values, validity, output
            )
            output += page.header.num_values
    if output != rows:
        raise Error("Decoded row count disagrees with footer")
    if null_count == 0:
        validity = List[UInt8]()
    return NumericColumn[dtype](values^, validity^, column_name, null_count)


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
