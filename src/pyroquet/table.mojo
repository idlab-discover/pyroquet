"""Owned mixed scalar tables and legacy chunked UInt32 construction helpers.

Numeric tables borrow typed storage immutably. Validity is packed LSB-first;
absent bitmaps mean all values are present. Schema owns field nullability.
"""

from std.utils import Variant
from numojo.routines.creation import empty
from .numeric_column import NumericColumn
from .binary_column import BinaryColumn
from .boolean_column import BooleanColumn
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


struct Column(Movable):
    """Own one scalar column and expose checked immutable typed borrows."""

    var _data: Variant[
        NumericColumn[DType.int8],
        NumericColumn[DType.uint8],
        NumericColumn[DType.int16],
        NumericColumn[DType.uint16],
        NumericColumn[DType.int32],
        NumericColumn[DType.uint32],
        NumericColumn[DType.int64],
        NumericColumn[DType.uint64],
        NumericColumn[DType.float32],
        NumericColumn[DType.float64],
        BooleanColumn,
        BinaryColumn,
    ]
    var _dtype: DType
    var _kind: Int
    var _name: String
    var _size: Int
    var _null_count: Int

    def __init__[dtype: DType](out self, var column: NumericColumn[dtype]):
        self._dtype = dtype
        self._kind = SchemaNode.numeric_kind[dtype]()
        self._name = column.name()
        self._size = column.size()
        self._null_count = column.null_count()
        self._data = column^

    def __init__(out self, var name: String, var column: BooleanColumn):
        self._dtype = DType.bool
        self._kind = SchemaNode.BOOLEAN
        self._name = name^
        self._size = len(column)
        self._null_count = column.null_count()
        self._data = column^

    def __init__(out self, var name: String, var column: BinaryColumn):
        self._dtype = DType.uint8
        self._kind = (
            SchemaNode.FIXED_BINARY if column.fixed_width() else SchemaNode.BINARY
        )
        self._name = name^
        self._size = len(column)
        self._null_count = column.null_count()
        self._data = column^

    def kind(self) -> Int:
        return self._kind

    def boolean(
        self,
    ) raises -> ref[origin_of(self._data[BooleanColumn])] BooleanColumn:
        if self._kind != SchemaNode.BOOLEAN:
            raise Error("Column is not Boolean")
        return self._data[BooleanColumn]

    def binary(
        self,
    ) raises -> ref[origin_of(self._data[BinaryColumn])] BinaryColumn:
        if (
            self._kind != SchemaNode.BINARY
            and self._kind != SchemaNode.FIXED_BINARY
        ):
            raise Error("Column is not binary")
        return self._data[BinaryColumn]

    def numeric[
        dtype: DType
    ](self) raises -> ref[
        origin_of(self._data[NumericColumn[dtype]])
    ] NumericColumn[dtype]:
        if self._kind != SchemaNode.numeric_kind[dtype]():
            raise Error("Column dtype does not match requested borrow")
        return self._data[NumericColumn[dtype]]

    def dtype(self) raises -> DType:
        if self._kind >= SchemaNode.BOOLEAN:
            raise Error("Non-numeric column has no numeric dtype")
        return self._dtype

    def name(self) -> String:
        return self._name

    def size(self) -> Int:
        return self._size

    def null_count(self) -> Int:
        return self._null_count

    def value(self, row: Int) raises -> Optional[UInt32]:
        """Compatibility shorthand for UInt32 columns; checks the dtype."""
        return self.numeric[DType.uint32]().value(row)


struct Table(Movable):
    """Own a validated flat mixed scalar table with immutable typed borrowing.

    Schema supplies names, order and nullability. Explicit row counts preserve
    zero-column projection shape. Storage moves into the table without copies.
    """

    var _schema: Schema
    var _columns: List[Column]
    var _num_rows: Int

    def __init__(
        out self,
        var schema: Schema,
        var columns: List[Column],
        num_rows: Int,
    ) raises:
        if num_rows < 0:
            raise Error("Negative table row count")
        if len(schema) - 1 != len(columns):
            raise Error("Table columns do not match flat schema")
        for i in range(len(columns)):
            var field = schema.node(i + 1)
            if field.parent() != 0 or field.kind() == SchemaNode.GROUP:
                raise Error("Only flat primitive materialization is implemented")
            if field.kind() != columns[i].kind():
                raise Error("Column dtype disagrees with schema")
            if (
                field.kind() == SchemaNode.FIXED_BINARY
                and field.fixed_width() != columns[i].binary().fixed_width()
            ):
                raise Error("Fixed binary storage width disagrees with schema")
            if field.name() != columns[i].name():
                raise Error("Column name disagrees with schema")
            if columns[i].size() != num_rows:
                raise Error("Table columns have inconsistent row counts")
            if not field.nullable() and columns[i].null_count() != 0:
                raise Error("Required field contains null values")
        self._schema = schema^
        self._columns = columns^
        self._num_rows = num_rows

    def __init__(
        out self,
        var schema: Schema,
        var columns: List[UInt32Column],
        num_rows: Int,
    ) raises:
        """Adapt legacy chunked UInt32 storage into the common numeric table."""
        if len(schema) - 1 != len(columns):
            raise Error("Table columns do not match flat schema")
        var numeric = List[Column]()
        for i in range(len(columns)):
            var values = empty[DType.uint32]([len(columns[i])])
            var validity = List[UInt8]()
            if columns[i].null_count():
                validity.resize(
                    len(columns[i]) // 8 + Int(len(columns[i]) % 8 != 0), 0
                )
            for row in range(len(columns[i])):
                var item = columns[i].value(row)
                values.unsafe_ptr()[
                    unsafe_offset=row
                ] = item.value() if item else UInt32(0)
                if item and len(validity):
                    validity[row // 8] |= UInt8(1) << UInt8(row % 8)
            numeric.append(
                Column(
                    NumericColumn(
                        values^,
                        validity^,
                        schema.node(i + 1).name(),
                        columns[i].null_count(),
                    )
                )
            )
        self = Self(schema^, numeric^, num_rows)

    def num_rows(self) -> Int:
        return self._num_rows

    def num_columns(self) -> Int:
        return len(self._columns)

    def schema(self) -> Schema:
        return self._schema.copy()

    def column(
        self, index: Int
    ) raises -> ref[origin_of(self._columns[0])] Column:
        if index < 0 or index >= len(self._columns):
            raise Error("Column index out of range")
        return self._columns[index]
