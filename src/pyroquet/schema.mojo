"""Schema hierarchy independent of Parquet's physical representations.

Nodes reference earlier parent nodes. This represents a tree without recursive
allocation. Numeric leaf identities are independent of their physical encoding.
"""

from .storage import FrozenBuffer


struct SchemaNode(Copyable, Movable):
    comptime GROUP = 0
    comptime UINT32 = 1
    comptime INT8 = 2
    comptime UINT8 = 3
    comptime INT16 = 4
    comptime UINT16 = 5
    comptime INT32 = 6
    comptime INT64 = 7
    comptime UINT64 = 8
    comptime FLOAT32 = 9
    comptime FLOAT64 = 10

    var _name: String
    var _kind: Int
    var _parent: Int
    var _nullable: Bool

    def __init__(
        out self,
        var name: String,
        kind: Int,
        parent: Int,
        nullable: Bool = False,
    ):
        self._name = name^
        self._kind = kind
        self._parent = parent
        self._nullable = nullable

    def name(self) -> String:
        return self._name.copy()

    def kind(self) -> Int:
        return self._kind

    @staticmethod
    def numeric_kind[dtype: DType]() -> Int:
        comptime if dtype == DType.uint32:
            return Self.UINT32
        comptime if dtype == DType.int8:
            return Self.INT8
        comptime if dtype == DType.uint8:
            return Self.UINT8
        comptime if dtype == DType.int16:
            return Self.INT16
        comptime if dtype == DType.uint16:
            return Self.UINT16
        comptime if dtype == DType.int32:
            return Self.INT32
        comptime if dtype == DType.int64:
            return Self.INT64
        comptime if dtype == DType.uint64:
            return Self.UINT64
        comptime if dtype == DType.float32:
            return Self.FLOAT32
        comptime if dtype == DType.float64:
            return Self.FLOAT64
        return -1

    def dtype(self) raises -> DType:
        if self._kind == Self.UINT32:
            return DType.uint32
        if self._kind == Self.INT8:
            return DType.int8
        if self._kind == Self.UINT8:
            return DType.uint8
        if self._kind == Self.INT16:
            return DType.int16
        if self._kind == Self.UINT16:
            return DType.uint16
        if self._kind == Self.INT32:
            return DType.int32
        if self._kind == Self.INT64:
            return DType.int64
        if self._kind == Self.UINT64:
            return DType.uint64
        if self._kind == Self.FLOAT32:
            return DType.float32
        if self._kind == Self.FLOAT64:
            return DType.float64
        raise Error("Schema node is not numeric")

    def parent(self) -> Int:
        return self._parent

    def nullable(self) -> Bool:
        return self._nullable


struct Schema(Copyable, Movable, Sized):
    """Validated shared tree. Node zero is the required, parentless root group.
    """

    var _nodes: FrozenBuffer[SchemaNode]

    def __init__(
        out self, var nodes: List[SchemaNode], max_depth: Int = 64
    ) raises:
        if len(nodes) == 0:
            raise Error("Schema requires a root group")
        if max_depth < 1:
            raise Error("Schema depth limit must be positive")
        if (
            nodes[0].kind() != SchemaNode.GROUP
            or nodes[0].parent() != -1
            or nodes[0].nullable()
        ):
            raise Error("Schema root must be a required parentless group")
        var depths = List[Int]()
        depths.append(0)
        for i in range(1, len(nodes)):
            var parent = nodes[i].parent()
            if parent < 0 or parent >= i:
                raise Error("Schema parent must precede its child")
            if nodes[parent].kind() != SchemaNode.GROUP:
                raise Error("Primitive schema node cannot have children")
            if (
                nodes[i].kind() < SchemaNode.GROUP
                or nodes[i].kind() > SchemaNode.FLOAT64
            ):
                raise Error("Unsupported schema type")
            var depth = depths[parent] + 1
            if depth > max_depth:
                raise Error("Schema nesting exceeds depth limit")
            depths.append(depth)
            for j in range(1, i):
                if (
                    nodes[j].parent() == parent
                    and nodes[j]._name == nodes[i]._name
                ):
                    raise Error("Duplicate sibling field name")
        self._nodes = FrozenBuffer(nodes^)

    def __len__(self) -> Int:
        return len(self._nodes)

    def node(self, index: Int) raises -> SchemaNode:
        return self._nodes[index]
