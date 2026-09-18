"""Validated UTF-8 columns sharing immutable binary arenas and native offsets."""

from .binary_column import BinaryBuilder, BinaryColumn


def _validate_utf8(bytes: Span[UInt8, _]) raises:
    """Reject invalid scalar encodings, including truncation at a value boundary.
    """
    var i = 0
    while i < len(bytes):
        var lead = Int(bytes[i])
        if lead < 128:
            i += 1
            continue
        var width: Int
        var lower = 128
        var upper = 191
        if lead >= 194 and lead <= 223:
            width = 2
        elif lead >= 224 and lead <= 239:
            width = 3
            if lead == 224:
                lower = 160
            elif lead == 237:
                upper = 159
        elif lead >= 240 and lead <= 244:
            width = 4
            if lead == 240:
                lower = 144
            elif lead == 244:
                upper = 143
        else:
            raise Error("Invalid STRING UTF-8 leading byte")
        if width > len(bytes) - i:
            raise Error("Truncated STRING UTF-8 value")
        if Int(bytes[i + 1]) < lower or Int(bytes[i + 1]) > upper:
            raise Error("Invalid STRING UTF-8 scalar")
        for j in range(2, width):
            if bytes[i + j] < 128 or bytes[i + j] > 191:
                raise Error("Invalid STRING UTF-8 continuation byte")
        i += width


def _validate_string_binary(binary: BinaryColumn) raises:
    if binary.fixed_width() != 0:
        raise Error("STRING requires variable-width BYTE_ARRAY storage")
    for row in range(len(binary)):
        if binary.is_valid(row):
            _validate_utf8(binary.value(row))


struct StringColumn(Copyable, Movable, Sized):
    """UTF-8 bytes, offsets and validity; copies share immutable storage.

    Construction validates each present value independently. Materialized String
    values own their bytes; binary() provides an immutable origin-bound borrow.
    """

    var _binary: BinaryColumn

    def __init__(out self, var binary: BinaryColumn) raises:
        _validate_string_binary(binary)
        self._binary = binary^

    def binary(self) -> ref[origin_of(self._binary)] BinaryColumn:
        return self._binary

    def __len__(self) -> Int:
        return len(self._binary)

    def null_count(self) -> Int:
        return self._binary.null_count()

    def byte_size(self) -> Int:
        return self._binary.byte_size()

    def is_valid(self, index: Int) raises -> Bool:
        return self._binary.is_valid(index)

    def value(self, index: Int) raises -> String:
        return String(from_utf8=self._binary.value(index))


struct StringBuilder(Movable, Sized):
    """Exclusive bounded construction; freeze consumes the builder."""

    var _binary: BinaryBuilder

    def __init__(
        out self, max_bytes: Int = 1073741824, byte_capacity: Int = 0
    ) raises:
        self._binary = BinaryBuilder(
            max_bytes=max_bytes, byte_capacity=byte_capacity
        )

    def __len__(self) -> Int:
        return len(self._binary)

    def append(mut self, value: String) raises:
        self._binary.append(value.as_bytes())

    def append_null(mut self) raises:
        self._binary.append_null()

    def freeze(deinit self) raises -> StringColumn:
        return StringColumn(self._binary^.freeze())
