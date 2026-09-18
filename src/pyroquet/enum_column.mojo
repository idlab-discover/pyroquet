"""String dictionaries with numojo-owned uint32 indices and explicit validity."""

from numojo.core.ndarray import NDArray
from numojo.routines.creation import empty
from .binary_column import BinaryColumn
from .numeric_column import NumericColumn
from .string_column import StringColumn, _validate_utf8


def _enum_cardinality(count: Int, max_labels: Int = 4294967296) raises:
    if max_labels < 0 or max_labels > 4294967296:
        raise Error("ENUM label limit outside uint32 cardinality")
    if count < 0 or count > max_labels:
        raise Error("ENUM dictionary cardinality exceeds limit")


def _enum_overhead(rows: Int, budget: Int) raises -> Int:
    if rows < 0 or budget < 0 or rows > (Int.MAX - 8) // 4:
        raise Error("Invalid ENUM row count or allocation overflow")
    var bitmap = rows // 8 + Int(rows % 8 != 0)
    var indices = rows * 4
    if bitmap > Int.MAX - 8 - indices:
        raise Error("ENUM allocation overflow")
    var overhead = indices + bitmap + 8
    if overhead > budget:
        raise Error("ENUM output budget exceeded")
    return overhead


struct EnumColumn(Movable, Sized):
    """Unique non-null UTF-8 labels and nullable indices; indices are not ordering.

    Unused labels are permitted, but neither their preservation nor dictionary
    order is promised by Parquet round trips. Copies of labels share immutable
    storage; the numeric index allocation remains exclusively owned.
    """

    var _labels: StringColumn
    var _indices: NumericColumn[DType.uint32]

    def __init__(
        out self,
        var labels: StringColumn,
        var indices: NumericColumn[DType.uint32],
    ) raises:
        _enum_cardinality(len(labels))
        if labels.null_count() != 0:
            raise Error("ENUM labels must be non-null")
        var seen = Dict[String, Bool]()
        for row in range(len(labels)):
            var label = labels.value(row)
            if label in seen:
                raise Error("ENUM labels must be unique")
            seen[label] = True
        for row in range(indices.size()):
            var index = indices.value(row)
            if index and Int(index.value()) >= len(labels):
                raise Error("ENUM index outside dictionary")
        self._labels = labels^
        self._indices = indices^

    def labels(self) -> ref[origin_of(self._labels)] StringColumn:
        return self._labels

    def indices(
        self,
    ) -> ref[origin_of(self._indices)] NumericColumn[DType.uint32]:
        return self._indices

    def __len__(self) -> Int:
        return self._indices.size()

    def null_count(self) -> Int:
        return self._indices.null_count()

    def is_valid(self, row: Int) raises -> Bool:
        return Bool(self._indices.value(row))

    def value(self, row: Int) raises -> String:
        var index = self._indices.value(row)
        if not index:
            raise Error("Cannot access a null ENUM value")
        return self._labels.value(Int(index.value()))

    def dictionary_byte_size(self) -> Int:
        return (
            self._labels.byte_size()
            + (len(self._labels) + 1) * 8
            + len(self._labels.binary()._validity)
        )

    def storage_byte_size(self) -> Int:
        return (
            self.dictionary_byte_size()
            + len(self) * 4
            + len(self._indices.validity())
        )


struct EnumBuilder(Movable, Sized):
    """Bounded interning into a single label arena, without expanded row storage.

    Output budget includes indices, bitmap, offsets and unique label bytes.
    Temporary hash keys duplicate unique UTF-8 payload (plus String terminators)
    and hash-table entries scale with the bounded unique label count. Allocator
    capacity and hash workspace are not part of the logical output-byte budget.
    """

    var _values: NDArray[DType.uint32]
    var _validity: List[UInt8]
    var _offsets: List[Int]
    var _bytes: List[UInt8]
    var _intern: Dict[String, UInt32]
    var _rows: Int
    var _position: Int
    var _nulls: Int
    var _used: Int
    var _limit: Int
    var _max_labels: Int

    def __init__(
        out self,
        row_count: Int,
        max_output_bytes: Int = 1073741824,
        max_labels: Int = 4294967296,
    ) raises:
        var overhead = _enum_overhead(row_count, max_output_bytes)
        _enum_cardinality(0, max_labels)
        self._values = empty[DType.uint32]([row_count])
        self._validity = List[UInt8](
            length=row_count // 8 + Int(row_count % 8 != 0), fill=0
        )
        self._offsets = [0]
        self._bytes = List[UInt8]()
        self._intern = Dict[String, UInt32]()
        self._rows = row_count
        self._position = 0
        self._nulls = 0
        self._used = overhead
        self._limit = max_output_bytes
        self._max_labels = max_labels

    def __len__(self) -> Int:
        return self._position

    def append(mut self, value: String) raises:
        self.append_bytes(value.as_bytes())

    def append_bytes(mut self, bytes: Span[UInt8, _]) raises:
        if self._position >= self._rows:
            raise Error("ENUM builder row count exceeded")
        _validate_utf8(bytes)
        # Bound even the temporary lookup String before allocating it.
        if len(bytes) > self._limit:
            raise Error("ENUM label exceeds output budget")
        var label = String(from_utf8=bytes)
        var index: UInt32
        if label in self._intern:
            index = self._intern[label]
        else:
            var count = len(self._offsets) - 1
            _enum_cardinality(count + 1, self._max_labels)
            if (
                self._limit - self._used < 8
                or len(bytes) > self._limit - self._used - 8
            ):
                raise Error("ENUM output budget exceeded")
            index = UInt32(count)
            self._intern[label] = index
            self._bytes.extend(bytes)
            self._offsets.append(len(self._bytes))
            self._used += 8 + len(bytes)
        self._values.unsafe_ptr()[unsafe_offset=self._position] = index
        self._validity[self._position // 8] |= UInt8(1) << UInt8(
            self._position % 8
        )
        self._position += 1

    def append_null(mut self) raises:
        if self._position >= self._rows:
            raise Error("ENUM builder row count exceeded")
        self._values.unsafe_ptr()[unsafe_offset=self._position] = 0
        self._position += 1
        self._nulls += 1

    def freeze(deinit self) raises -> EnumColumn:
        if self._position != self._rows:
            raise Error("ENUM builder row count incomplete")
        return EnumColumn(
            StringColumn(BinaryColumn(self._offsets^, self._bytes^)),
            NumericColumn[DType.uint32](
                self._values^, self._validity^, "", self._nulls
            ),
        )
