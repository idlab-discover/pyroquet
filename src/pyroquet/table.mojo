"""Owned mixed scalar tables with shared numeric storage.

Numeric values use shared NuMojo storage. Validity is packed LSB-first;
absent bitmaps mean all values are present. Schema owns field nullability.
"""

from std.utils import Variant
from numojo.core.ndarray import NDArray
from .numeric_column import NumericColumn
from .binary_column import BinaryColumn
from .string_column import StringColumn
from .enum_column import EnumColumn
from .boolean_column import BooleanColumn
from .schema import Schema, SchemaNode


struct Column(Movable):
    """Own one scalar column with checked typed access and shared numeric values.
    """

    var _data: Variant[
        NumericColumn[DType.int8],
        NumericColumn[DType.uint8],
        NumericColumn[DType.int16],
        NumericColumn[DType.uint16],
        NumericColumn[DType.int32],
        NumericColumn[DType.uint32],
        NumericColumn[DType.int64],
        NumericColumn[DType.uint64],
        NumericColumn[DType.float16],
        NumericColumn[DType.float32],
        NumericColumn[DType.float64],
        BooleanColumn,
        BinaryColumn,
        StringColumn,
        EnumColumn,
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

    def __init__(out self, var name: String, var column: StringColumn):
        self._dtype = DType.uint8
        self._kind = SchemaNode.STRING
        self._name = name^
        self._size = len(column)
        self._null_count = column.null_count()
        self._data = column^

    def string(
        self,
    ) raises -> ref[origin_of(self._data[StringColumn])] StringColumn:
        if self._kind != SchemaNode.STRING:
            raise Error("Column is not string")
        return self._data[StringColumn]

    def __init__(out self, var name: String, var column: EnumColumn):
        self._dtype = DType.uint32
        self._kind = SchemaNode.ENUM
        self._name = name^
        self._size = len(column)
        self._null_count = column.null_count()
        self._data = column^

    def enumeration(
        self,
    ) raises -> ref[origin_of(self._data[EnumColumn])] EnumColumn:
        if self._kind != SchemaNode.ENUM:
            raise Error("Column is not ENUM")
        return self._data[EnumColumn]

    def _byte_value(
        self, row: Int
    ) raises -> Span[
        UInt8,
        origin_of(
            self._data[BinaryColumn]._bytes._owner,
            self._data[StringColumn]._binary._bytes._owner,
            self._data[EnumColumn]._labels._binary._bytes._owner,
        ),
    ]:
        """Borrow physical value bytes without erasing the public logical type.
        """
        comptime Result = Span[
            UInt8,
            origin_of(
                self._data[BinaryColumn]._bytes._owner,
                self._data[StringColumn]._binary._bytes._owner,
                self._data[EnumColumn]._labels._binary._bytes._owner,
            ),
        ]
        if self._kind == SchemaNode.ENUM:
            ref column = self.enumeration()
            var index = column.indices().value(row)
            if not index:
                raise Error("Cannot borrow a null ENUM value")
            return rebind[Result](
                column.labels().binary().value(Int(index.value()))
            )
        return rebind[Result](self._binary_storage().value(row))

    def _binary_storage(
        self,
    ) raises -> ref[
        origin_of(self._data[StringColumn]._binary, self._data[BinaryColumn])
    ] BinaryColumn:
        """Internal shared byte storage; public borrows retain logical identity.
        """
        if self._kind == SchemaNode.STRING:
            return self._data[StringColumn].binary()
        return self.binary()

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

    def values_mut[dtype: DType](self) raises -> NDArray[dtype]:
        """Retain shared numeric values without exposing column replacement."""
        return self.numeric[dtype]().values_mut()

    def set_enum_index(mut self, row: Int, code: UInt32) raises:
        if self._kind != SchemaNode.ENUM:
            raise Error("Column is not ENUM")
        self._data[EnumColumn].set_index(row, code)

    def dtype(self) raises -> DType:
        if SchemaNode.BOOLEAN <= self._kind <= SchemaNode.ENUM:
            raise Error("Non-numeric column has no numeric dtype")
        return self._dtype

    def name(self) -> String:
        return self._name

    def size(self) -> Int:
        return self._size

    def null_count(self) -> Int:
        return self._null_count


struct Table(Movable):
    """Own a validated flat mixed scalar table with shared numeric value access.

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
                raise Error(
                    "Only flat primitive materialization is implemented"
                )
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

    def values_mut[dtype: DType](self, index: Int) raises -> NDArray[dtype]:
        """Retain a shared numeric value handle; schema/validity stay fixed."""
        return self.column(index).values_mut[dtype]()

    def set_enum_index(mut self, index: Int, row: Int, code: UInt32) raises:
        if index < 0 or index >= len(self._columns):
            raise Error("Column index out of range")
        self._columns[index].set_enum_index(row, code)
