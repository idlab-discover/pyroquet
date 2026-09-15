"""Schema hierarchy independent of Parquet's physical representations.

Nodes reference earlier parent nodes. This represents a tree without recursive
allocation. Only group and UInt32 identities are implemented in this slice.
"""

from .storage import FrozenBuffer


struct SchemaNode(Copyable, Movable):
    comptime GROUP = 0
    comptime UINT32 = 1

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
                nodes[i].kind() != SchemaNode.GROUP
                and nodes[i].kind() != SchemaNode.UINT32
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
