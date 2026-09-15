"""Owned chunked tables: first materializable logical type is UInt32.

Validity is separate from values and uses least-significant-bit-first packed
bits. An absent bitmap means all valid. Column chunk boundaries are independent.
"""

from .schema import Schema, SchemaNode
from .storage import FrozenBuffer


struct UInt32Chunk(Copyable, Movable, Sized):
    var _values: FrozenBuffer[UInt32]
    var _validity: FrozenBuffer[UInt8]
    var _null_count: Int

    def __init__(
        out self,
        var values: List[UInt32],
        var validity: List[UInt8] = List[UInt8](),
    ) raises:
        var count = len(values)
        var bitmap_bytes = count // 8 + Int(count % 8 != 0)
        if len(validity) != 0 and len(validity) != bitmap_bytes:
            raise Error("Validity bitmap does not match chunk length")
        self._null_count = 0
        if len(validity) != 0:
            if (
                count % 8 != 0
                and (validity[len(validity) - 1] >> UInt8(count % 8)) != 0
            ):
                raise Error("Validity bitmap has nonzero padding bits")
            for i in range(count):
                self._null_count += Int(
                    (validity[i // 8] & (UInt8(1) << UInt8(i % 8))) == 0
                )
        self._values = FrozenBuffer(values^)
        self._validity = FrozenBuffer(validity^)

    def __len__(self) -> Int:
        return len(self._values)

    def null_count(self) -> Int:
        return self._null_count

    def value(self, index: Int) raises -> Optional[UInt32]:
        if index < 0 or index >= len(self):
            raise Error("Row outside chunk")
        if len(self._validity) != 0:
            if (
                self._validity[index // 8] & (UInt8(1) << UInt8(index % 8))
            ) == 0:
                return None
        return self._values[index]


struct UInt32Column(Copyable, Movable, Sized):
    var _chunks: FrozenBuffer[UInt32Chunk]
    var _length: Int
    var _null_count: Int

    def __init__(out self, var chunks: List[UInt32Chunk]) raises:
        self._length = 0
        self._null_count = 0
        for chunk in chunks:
            if len(chunk) > Int.MAX - self._length:
                raise Error("Column row count overflow")
            self._length += len(chunk)
            self._null_count += chunk.null_count()
        self._chunks = FrozenBuffer(chunks^)

    def __len__(self) -> Int:
        return self._length

    def null_count(self) -> Int:
        return self._null_count

    def num_chunks(self) -> Int:
        return len(self._chunks)

    def chunk(self, index: Int) raises -> UInt32Chunk:
        return self._chunks[index]

    def value(self, row: Int) raises -> Optional[UInt32]:
        if row < 0 or row >= self._length:
            raise Error("Row outside column")
        var remaining = row
        var chunks = self._chunks.view()
        for chunk in chunks:
            if remaining < len(chunk):
                return chunk.value(remaining)
            remaining -= len(chunk)
        raise Error("Invalid column row accounting")


struct Table(Copyable, Movable):
    """Validated flat UInt32 table; nested materialization is explicitly rejected.

    An explicit row count preserves the shape of a table with zero columns.
    Copying a table shares immutable schema, chunks, values and validity.
    """

    var _schema: Schema
    var _columns: FrozenBuffer[UInt32Column]
    var _num_rows: Int

    def __init__(
        out self,
        var schema: Schema,
        var columns: List[UInt32Column],
        num_rows: Int,
    ) raises:
        if num_rows < 0:
            raise Error("Negative table row count")
        if len(schema) - 1 != len(columns):
            raise Error("Table columns do not match flat schema")
        for i in range(len(columns)):
            var field = schema.node(i + 1)
            if field.parent() != 0 or field.kind() != SchemaNode.UINT32:
                raise Error("Only flat UInt32 materialization is implemented")
            if len(columns[i]) != num_rows:
                raise Error("Table columns have inconsistent row counts")
            if not field.nullable() and columns[i].null_count() != 0:
                raise Error("Required field contains null values")
        self._schema = schema^
        self._columns = FrozenBuffer(columns^)
        self._num_rows = num_rows

    def num_rows(self) -> Int:
        return self._num_rows

    def num_columns(self) -> Int:
        return len(self._columns)

    def schema(self) -> Schema:
        return self._schema.copy()

    def column(self, index: Int) raises -> UInt32Column:
        return self._columns[index]
