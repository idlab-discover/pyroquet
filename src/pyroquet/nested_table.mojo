"""Explicit nested ownership: schema-indexed structure and typed leaf owners.

GROUP means a non-repeated STRUCT. LIST has one primitive child; wire wrappers
are not logical schema nodes. Struct children retain a slot for every parent;
list offsets address compact element slots. Absent ancestors mask descendants.
"""
from std.sys import size_of
from .schema import Schema, SchemaNode
from .table import Column
from .storage import FrozenBuffer


struct NestedStructure(Copyable, Movable):
    var _size: Int
    var _validity: FrozenBuffer[UInt8]
    var _offsets: FrozenBuffer[Int]

    def __init__(
        out self,
        size: Int,
        var validity: List[UInt8] = List[UInt8](),
        var offsets: List[Int] = List[Int](),
    ) raises:
        if size < 0:
            raise Error("Negative nested structure size")
        if len(validity) != 0:
            if len(validity) != size // 8 + Int(size % 8 != 0):
                raise Error("Nested validity length mismatch")
            if size % 8 and validity[len(validity) - 1] >> UInt8(size % 8):
                raise Error("Nonzero nested validity padding")
        if len(offsets) != 0:
            if size == Int.MAX or len(offsets) != size + 1 or offsets[0] != 0:
                raise Error("Invalid LIST offsets")
            for i in range(size):
                if offsets[i] < 0 or offsets[i + 1] < offsets[i]:
                    raise Error("Nonmonotone LIST offsets")
                if len(validity) and not (
                    validity[i // 8] & (UInt8(1) << UInt8(i % 8))
                ):
                    if offsets[i + 1] != offsets[i]:
                        raise Error("Null LIST must have no child elements")
        self._size = size
        self._validity = FrozenBuffer(validity^)
        self._offsets = FrozenBuffer(offsets^)

    def size(self) -> Int:
        return self._size

    def is_valid(self, row: Int) raises -> Bool:
        if row < 0 or row >= self._size:
            raise Error("Nested row out of range")
        return len(self._validity) == 0 or Bool(
            self._validity[row // 8] & (UInt8(1) << UInt8(row % 8))
        )

    def offset(self, row: Int) raises -> Int:
        return self._offsets[row]

    def child_count(self) raises -> Int:
        if len(self._offsets):
            return self._offsets[self._size]
        return self._size

    def is_list(self) -> Bool:
        return len(self._offsets) != 0

    def retained_bytes(self) raises -> Int:
        if (
            len(self._offsets)
            > (Int.MAX - len(self._validity)) // size_of[Int]()
        ):
            raise Error("Nested storage size overflow")
        return len(self._validity) + len(self._offsets) * size_of[Int]()


def _column_valid(column: Column, row: Int) raises -> Bool:
    if column.kind() == SchemaNode.ENUM:
        return column.enumeration().is_valid(row)
    if column.kind() == SchemaNode.STRING:
        return column.string().is_valid(row)
    if column.kind() == SchemaNode.BOOLEAN:
        return Bool(column.boolean().value(row))
    if (
        column.kind() == SchemaNode.BINARY
        or column.kind() == SchemaNode.FIXED_BINARY
    ):
        return column.binary().is_valid(row)
    comptime types = (
        DType.int8,
        DType.uint8,
        DType.int16,
        DType.uint16,
        DType.int32,
        DType.uint32,
        DType.int64,
        DType.uint64,
        DType.float32,
        DType.float64,
    )
    comptime for t in range(len(types)):
        comptime dtype = types[t]
        if column.kind() == SchemaNode.numeric_kind[dtype]():
            return Bool(column.numeric[dtype]().value(row))
    raise Error("Unsupported nested primitive")


struct NestedTable(Movable):
    """Move-owned leaves and immutable structure; all borrowed leaves stay owner-tied.

    Leaves follow primitive schema order. Structures follow GROUP/LIST schema
    order, excluding root. Parent links, rather than dotted names, identify nodes.
    """

    var _schema: Schema
    var _leaves: List[Column]
    var _structures: List[NestedStructure]
    var _structure_indices: List[Int]
    var _leaf_indices: List[Int]
    var _num_rows: Int

    def __init__(
        out self,
        var schema: Schema,
        var leaves: List[Column],
        var structures: List[NestedStructure],
        num_rows: Int,
    ) raises:
        if num_rows < 0:
            raise Error("Negative nested table row count")
        var si = List[Int](length=len(schema), fill=-1)
        var li = List[Int](length=len(schema), fill=-1)
        var sizes = List[Int](length=len(schema), fill=num_rows)
        var leaf_count = 0
        var structure_count = 0
        for i in range(1, len(schema)):
            var node = schema.node(i)
            var parent = node.parent()
            var count = sizes[parent]
            if parent and schema.node(parent).kind() == SchemaNode.LIST:
                if node.name() != "element":
                    raise Error("Logical LIST child must be named element")
                count = structures[si[parent]].child_count()
            sizes[i] = count
            var group = (
                node.kind() == SchemaNode.GROUP
                or node.kind() == SchemaNode.LIST
            )
            if group:
                if structure_count >= len(structures):
                    raise Error("Missing nested structure")
                si[i] = structure_count
                structure_count += 1
                if structures[si[i]].size() != count or structures[
                    si[i]
                ].is_list() != (node.kind() == SchemaNode.LIST):
                    raise Error("Nested structure shape disagrees with schema")
            else:
                if leaf_count >= len(leaves):
                    raise Error("Missing nested leaf")
                li[i] = leaf_count
                leaf_count += 1
                if (
                    leaves[li[i]].size() != count
                    or leaves[li[i]].kind() != node.kind()
                    or leaves[li[i]].name() != node.name()
                ):
                    raise Error("Nested leaf disagrees with schema")
                if (
                    node.kind() == SchemaNode.FIXED_BINARY
                    and leaves[li[i]].binary().fixed_width()
                    != node.fixed_width()
                ):
                    raise Error("Nested fixed binary width mismatch")
            for row in range(count):
                var present = structures[si[i]].is_valid(
                    row
                ) if group else _column_valid(leaves[li[i]], row)
                var parent_present = True
                if parent and schema.node(parent).kind() == SchemaNode.GROUP:
                    parent_present = structures[si[parent]].is_valid(row)
                if not parent_present and present:
                    raise Error("Present nested child under absent STRUCT")
                if parent_present and not present and not node.nullable():
                    raise Error("Required nested field is null")
        if leaf_count != len(leaves) or structure_count != len(structures):
            raise Error("Extra nested storage outside schema")
        self._schema = schema^
        self._leaves = leaves^
        self._structures = structures^
        self._structure_indices = si^
        self._leaf_indices = li^
        self._num_rows = num_rows

    def schema(self) -> Schema:
        return self._schema.copy()

    def num_rows(self) -> Int:
        return self._num_rows

    def num_leaves(self) -> Int:
        return len(self._leaves)

    def leaf(self, index: Int) raises -> ref[origin_of(self._leaves[0])] Column:
        if index < 0 or index >= len(self._leaves):
            raise Error("Nested leaf index out of range")
        return self._leaves[index]

    def leaf_index(self, schema_index: Int) raises -> Int:
        if (
            schema_index < 1
            or schema_index >= len(self._schema)
            or self._leaf_indices[schema_index] < 0
        ):
            raise Error("Schema node is not a nested leaf")
        return self._leaf_indices[schema_index]

    def structure(
        self, schema_index: Int
    ) raises -> ref[origin_of(self._structures[0])] NestedStructure:
        if (
            schema_index < 1
            or schema_index >= len(self._schema)
            or self._structure_indices[schema_index] < 0
        ):
            raise Error("Schema node is not a nested structure")
        return self._structures[self._structure_indices[schema_index]]
