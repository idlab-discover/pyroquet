"""Bounded STRUCT/primitive-LIST reading with explicit component projections.

LogicalTypes.md Lists/Backward-compatibility rules control legacy interpretation.
Two passes establish exact storage cardinalities before typed materialization.
"""
from std.io.file import FileHandle
from std.sys import size_of
from compact_protocol import CompactLimits
from numojo.routines.creation import empty
from .format.footer import _read_footer_bytes_from_file
from .format.metadata import (
    FileMetadata,
    SchemaElement,
    parse_metadata,
    validate_file_ranges,
)
from .format.pages import PageLimits, PageHeader, _ColumnPages
from .format.nested_levels import _NestedLevels
from .format.flat_pages import _page_body
from .format.hybrid import _HybridDecoder
from .format.delta import _DeltaDecoder
from .format.binary_values import decode_plain_binary
from .format.boolean_values import decode_boolean_values
from .numojo_io import (
    _matches_numeric,
    _plain_value,
    _plain_dictionary,
    _check_dictionary_header,
    _delta_value,
)
from .binary_io import _binary_kind
from .numeric_column import NumericColumn
from .binary_column import BinaryColumn, BinaryBuilder
from .boolean_column import BooleanColumn
from .schema import Schema, SchemaNode
from .table import Column
from .nested_table import NestedTable, NestedStructure
from .compression import validate_codec


def _bitmap_bytes(count: Int) -> Int:
    return count // 8 + Int(count % 8 != 0)


def _charge(mut budget: Int, amount: Int) raises:
    if amount < 0 or amount > budget:
        raise Error("Nested output budget exceeded")
    budget -= amount


def _leaf_overhead(kind: Int, count: Int, budget: Int) raises -> Int:
    if count < 0 or budget < 0:
        raise Error("Invalid nested child count/budget")
    var bytes = _bitmap_bytes(count)
    if bytes > budget:
        raise Error("Nested leaf validity exceeds budget")
    if kind == SchemaNode.BOOLEAN:
        if bytes > budget - bytes:
            raise Error("Nested Boolean output exceeds budget")
        return bytes * 2
    var width = 8
    if kind == SchemaNode.INT8 or kind == SchemaNode.UINT8:
        width = 1
    elif kind == SchemaNode.INT16 or kind == SchemaNode.UINT16:
        width = 2
    elif (
        kind == SchemaNode.INT32
        or kind == SchemaNode.UINT32
        or kind == SchemaNode.FLOAT32
    ):
        width = 4
    var extra = Int(
        kind == SchemaNode.BINARY or kind == SchemaNode.FIXED_BINARY
    )
    if count > (budget - bytes) // width - extra:
        raise Error("Nested child allocation exceeds budget")
    return bytes + (count + extra) * width


def _kind(node: SchemaElement) -> Int:
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
    comptime for i in range(len(types)):
        if _matches_numeric[types[i]](node):
            return SchemaNode.numeric_kind[types[i]]()
    var flat = node.copy()
    flat.parent = 0
    flat.max_repetition_level = 0
    return _binary_kind(flat)


def _is_list(node: SchemaElement) -> Bool:
    return node.logical_type == 3 or (
        node.logical_type == -1 and node.converted_type == 3
    )


struct _ReadPlan(Movable):
    var nodes: List[SchemaNode]
    var thresholds: List[Int]
    var leaves: List[Int]
    var leaf_nodes: List[Int]
    var columns: List[Int]
    var repeated_def: List[Int]

    def __init__(
        out self,
        metadata: FileMetadata,
        var projection: Optional[List[List[String]]],
    ) raises:
        self.nodes = [SchemaNode(metadata.schema[0].name, SchemaNode.GROUP, -1)]
        self.thresholds = [0]
        self.leaves = []
        self.leaf_nodes = []
        self.columns = []
        self.repeated_def = []
        var selected = List[Bool](length=len(metadata.schema), fill=False)
        if projection:
            var paths = projection.take()
            var roots = List[Int]()
            for path in paths:
                if len(path) == 0:
                    raise Error("Empty component projection path")
                var parent = 0
                for j in range(len(path)):
                    if parent != 0 and (
                        _is_list(metadata.schema[parent])
                        or metadata.schema[parent].repetition == 2
                        or not metadata.schema[parent].is_group()
                    ):
                        raise Error(
                            "Component projection traverses only non-repeated"
                            " STRUCTs"
                        )
                    var found = -1
                    for i in range(1, len(metadata.schema)):
                        if (
                            metadata.schema[i].parent == parent
                            and metadata.schema[i].name == path[j]
                        ):
                            found = i
                            break
                    if found == -1:
                        raise Error(
                            "Nested projection component not found: " + path[j]
                        )
                    parent = found
                for prior in roots:
                    var cursor = parent
                    while cursor > 0:
                        if cursor == prior:
                            raise Error(
                                "Duplicate/overlapping nested projection"
                            )
                        cursor = metadata.schema[cursor].parent
                    cursor = prior
                    while cursor > 0:
                        if cursor == parent:
                            raise Error(
                                "Duplicate/overlapping nested projection"
                            )
                        cursor = metadata.schema[cursor].parent
                roots.append(parent)
            for i in range(1, len(metadata.schema)):
                var cursor = i
                while cursor > 0:
                    for target in roots:
                        if target == cursor:
                            selected[i] = True
                    cursor = metadata.schema[cursor].parent
            for target in roots:
                var cursor = target
                while cursor > 0:
                    selected[cursor] = True
                    cursor = metadata.schema[cursor].parent
        else:
            for i in range(1, len(selected)):
                selected[i] = True
        var mapping = List[Int](length=len(metadata.schema), fill=-1)
        mapping[0] = 0
        var suppressed = List[Bool](length=len(metadata.schema), fill=False)
        var element_repeat = List[Int](length=len(metadata.schema), fill=-1)
        var column = 0
        for i in range(1, len(metadata.schema)):
            var original = metadata.schema[i].copy()
            var column_index = column
            if not original.is_group():
                column += 1
            if not selected[i] or suppressed[i]:
                continue
            var parent = mapping[original.parent]
            if parent < 0:
                raise Error("Unresolved nested schema parent")
            if _is_list(original):
                if (
                    not original.is_group()
                    or original.repetition == 2
                    or original.max_repetition_level != 0
                    or original.num_children != 1
                ):
                    raise Error(
                        "Unsupported LIST shape; one repeated ancestor per leaf"
                    )
                var repeated = i + 1
                if (
                    repeated >= len(metadata.schema)
                    or metadata.schema[repeated].parent != i
                    or metadata.schema[repeated].repetition != 2
                ):
                    raise Error("LIST must contain one repeated field")
                var element = repeated
                if metadata.schema[repeated].is_group():
                    # Rules 2-4 imply LIST<STRUCT> / LIST<LIST>, outside scope.
                    if (
                        metadata.schema[repeated].num_children != 1
                        or metadata.schema[repeated].name == "array"
                        or metadata.schema[repeated].name
                        == original.name + "_tuple"
                    ):
                        raise Error(
                            "Legacy LIST has STRUCT elements (LogicalTypes.md"
                            " Lists rules 2-4)"
                        )
                    element += 1
                    if (
                        element >= len(metadata.schema)
                        or metadata.schema[element].parent != repeated
                        or metadata.schema[element].is_group()
                        or metadata.schema[element].repetition == 2
                    ):
                        raise Error(
                            "LIST elements must be non-repeated supported"
                            " primitives"
                        )
                    if (
                        metadata.schema[repeated].logical_type != -1
                        or metadata.schema[repeated].converted_type != -1
                    ):
                        raise Error("Annotated LIST wrapper is unsupported")
                    suppressed[repeated] = True
                mapping[i] = len(self.nodes)
                mapping[repeated] = len(self.nodes)
                self.nodes.append(
                    SchemaNode(
                        original.name,
                        SchemaNode.LIST,
                        parent,
                        original.nullable(),
                    )
                )
                self.thresholds.append(original.max_definition_level)
                element_repeat[element] = metadata.schema[
                    repeated
                ].max_definition_level
                continue
            if original.is_group():
                if (
                    original.repetition == 2
                    or original.max_repetition_level != 0
                    or original.logical_type != -1
                    or original.converted_type != -1
                ):
                    raise Error(
                        "Selected group is not a supported non-repeated STRUCT"
                    )
                mapping[i] = len(self.nodes)
                self.nodes.append(
                    SchemaNode(
                        original.name,
                        SchemaNode.GROUP,
                        parent,
                        original.nullable(),
                    )
                )
                self.thresholds.append(original.max_definition_level)
                continue
            var kind = _kind(original)
            if kind < 0 or original.max_repetition_level > 1:
                raise Error(
                    "Selected nested leaf has unsupported physical/logical type"
                )
            var repeat = element_repeat[i]
            var name = original.name.copy()
            var nullable = original.nullable()
            if original.repetition == 2 and repeat == -1:
                # LogicalTypes.md Nested Types: unannotated repeated primitive
                # is a required LIST with required elements.
                if original.max_repetition_level != 1:
                    raise Error("Unsupported repeated leaf")
                mapping[i] = len(self.nodes)
                self.nodes.append(
                    SchemaNode(name, SchemaNode.LIST, parent, False)
                )
                self.thresholds.append(original.max_definition_level - 1)
                parent = len(self.nodes) - 1
                name = "element"
                repeat = original.max_definition_level
                nullable = False
            elif repeat != -1:
                name = "element"
                parent = mapping[original.parent]
                nullable = original.repetition == 1
            elif original.max_repetition_level != 0:
                raise Error("Repeated leaf lacks a supported LIST ancestor")
            self.leaves.append(i)
            self.leaf_nodes.append(len(self.nodes))
            self.columns.append(column_index)
            self.repeated_def.append(repeat)
            self.nodes.append(
                SchemaNode(
                    name,
                    kind,
                    parent,
                    nullable,
                    original.type_length if kind
                    == SchemaNode.FIXED_BINARY else 0,
                )
            )
            self.thresholds.append(original.max_definition_level)

    def take_schema(deinit self) raises -> Schema:
        return Schema(self.nodes^)


struct _StructureState(Movable):
    var validity: List[UInt8]
    var offsets: List[Int]
    var filled: Bool

    def __init__(out self):
        self.validity = []
        self.offsets = []
        self.filled = False

    def freeze(deinit self, rows: Int) raises -> NestedStructure:
        return NestedStructure(rows, self.validity^, self.offsets^)


def _ancestors(plan: _ReadPlan, leaf: Int) -> List[Int]:
    var ancestors = List[Int]()
    var parent = plan.nodes[plan.leaf_nodes[leaf]].parent()
    while parent > 0:
        ancestors.append(parent)
        parent = plan.nodes[parent].parent()
    return ancestors^


def _scan_leaf(
    mut file: FileHandle,
    metadata: FileMetadata,
    plan: _ReadPlan,
    leaf: Int,
    mut states: List[_StructureState],
    budget: Int,
    limits: PageLimits,
) raises -> Int:
    var selected = plan.leaves[leaf]
    var node = metadata.schema[selected].copy()
    var repeated = plan.repeated_def[leaf]
    var ancestors = _ancestors(plan, leaf)
    var rows = 0
    var children = 0
    var previous_element = False
    for group in metadata.row_groups:
        var col = group.columns[plan.columns[leaf]].copy()
        validate_codec(col.codec)
        var cursor = _ColumnPages(
            col.copy(), group.num_rows, node.max_repetition_level, limits
        )
        var group_rows = 0
        var previous_v2 = False
        while True:
            var next = cursor.next(file)
            if not next:
                break
            var h = next.value().header
            if h.page_type == 2:
                continue
            var data = file.read_bytes(h.compressed_page_size)
            data = _page_body(data^, h, col.codec)
            var levels = _NestedLevels(
                data, h, node.max_repetition_level, node.max_definition_level
            )
            for event in range(h.num_values):
                var pair = levels.next(data)
                var rep = pair[0]
                var definition = pair[1]
                var is_element = repeated < 0 or definition >= repeated
                if rep == 0:
                    if group_rows >= Int(group.num_rows) or rows >= Int(
                        metadata.num_rows
                    ):
                        raise Error("Nested rows exceed row-group declarations")
                    group_rows += 1
                    rows += 1
                    for ancestor in ancestors:
                        var valid = definition >= plan.thresholds[ancestor]
                        var row = rows - 1
                        var mask = UInt8(1) << UInt8(row % 8)
                        if states[ancestor].filled:
                            if (
                                Bool(states[ancestor].validity[row // 8] & mask)
                                != valid
                            ):
                                raise Error(
                                    "Inconsistent sibling STRUCT validity"
                                )
                        elif valid:
                            states[ancestor].validity[row // 8] |= mask
                        if len(states[ancestor].offsets) != 0:
                            states[ancestor].offsets[rows] = children
                else:
                    if (
                        group_rows == 0
                        or not previous_element
                        or not is_element
                    ):
                        raise Error("Invalid list repetition transition")
                    if event == 0 and (
                        previous_v2 or col.offset_index_offset != -1
                    ):
                        raise Error("Indexed/V2 pages cannot split a row")
                if is_element:
                    if children == Int.MAX:
                        raise Error("Nested child count overflow")
                    children += 1
                    _ = _leaf_overhead(
                        plan.nodes[plan.leaf_nodes[leaf]].kind(),
                        children,
                        budget,
                    )
                    if repeated >= 0:
                        states[ancestors[0]].offsets[rows] = children
                previous_element = is_element
            levels.finish()
            previous_v2 = h.page_type == 3
        if group_rows != Int(group.num_rows):
            raise Error("Nested level rows disagree with row group")
        previous_element = False
    if rows != Int(metadata.num_rows):
        raise Error("Nested rows disagree with file")
    for ancestor in ancestors:
        states[ancestor].filled = True
    return children


def _page_counts(
    data: List[UInt8], h: PageHeader, node: SchemaElement
) raises -> Tuple[Int, Int]:
    var levels = _NestedLevels(
        data, h, node.max_repetition_level, node.max_definition_level
    )
    for _ in range(h.num_values):
        _ = levels.next(data)
    levels.finish()
    return levels.start, levels.present


def _read_numeric[
    dtype: DType
](
    mut file: FileHandle,
    metadata: FileMetadata,
    plan: _ReadPlan,
    leaf: Int,
    count: Int,
    limits: PageLimits,
) raises -> Column:
    var node = metadata.schema[plan.leaves[leaf]].copy()
    var values = empty[dtype]([count])
    var bitmap = List[UInt8](length=_bitmap_bytes(count), fill=0)
    var output = 0
    var nulls = 0
    var repeated = plan.repeated_def[leaf]
    for group in metadata.row_groups:
        var col = group.columns[plan.columns[leaf]].copy()
        var cursor = _ColumnPages(
            col.copy(), group.num_rows, node.max_repetition_level, limits
        )
        var dictionary = List[Scalar[dtype]]()
        var has_dictionary = False
        while True:
            var next = cursor.next(file)
            if not next:
                break
            var h = next.value().header
            if h.page_type == 2:
                _check_dictionary_header[dtype](h, limits.max_page_bytes)
            var data = file.read_bytes(h.compressed_page_size)
            data = _page_body(data^, h, col.codec)
            if h.page_type == 2:
                dictionary = _plain_dictionary[dtype](data, h.num_values)
                has_dictionary = True
                continue
            var framing = _page_counts(data, h, node)
            var pos = framing[0]
            var present = framing[1]
            var levels = _NestedLevels(
                data, h, node.max_repetition_level, node.max_definition_level
            )
            var indexed = h.encoding == 2 or h.encoding == 8
            var ids = _HybridDecoder(0, 0, 0, 0)
            var delta = _DeltaDecoder[
                64 if size_of[Scalar[dtype]]() == 8 else 32
            ](data, len(data), len(data), 0)
            if indexed:
                if not has_dictionary or pos >= len(data):
                    raise Error("Nested numeric dictionary/ID width missing")
                ids = _HybridDecoder(
                    pos + 1, len(data), Int(data[pos]), present
                )
            elif h.encoding == 5:
                comptime if dtype == DType.float32 or dtype == DType.float64:
                    raise Error("Delta requires physical INT32/INT64")
                else:
                    delta = _DeltaDecoder[
                        64 if size_of[Scalar[dtype]]() == 8 else 32
                    ](data, pos, len(data), present)
            elif h.encoding == 0:
                comptime width = 8 if size_of[Scalar[dtype]]() == 8 else 4
                if (len(data) - pos) % width != 0 or (
                    len(data) - pos
                ) // width != present:
                    raise Error("Nested PLAIN payload/count mismatch")
            else:
                raise Error("Unsupported nested numeric encoding")
            for _ in range(h.num_values):
                var pair = levels.next(data)
                var definition = pair[1]
                if repeated >= 0 and definition < repeated:
                    continue
                if output >= count:
                    raise Error(
                        "Nested numeric child count changed during read"
                    )
                var value = Scalar[dtype](0)
                if definition == node.max_definition_level:
                    bitmap[output // 8] |= UInt8(1) << UInt8(output % 8)
                    if indexed:
                        var index = Int(ids.next(data))
                        if index >= len(dictionary):
                            raise Error(
                                "Nested numeric dictionary index out of range"
                            )
                        value = dictionary[index]
                    elif h.encoding == 5:
                        value = _delta_value[dtype](delta.next(data))
                    else:
                        value = _plain_value[dtype](data, pos)
                        pos += 8 if size_of[Scalar[dtype]]() == 8 else 4
                else:
                    nulls += 1
                values.unsafe_ptr()[unsafe_offset=output] = value
                output += 1
            levels.finish()
            if indexed:
                ids.finish()
            elif h.encoding == 5:
                delta.finish()
    if output != count:
        raise Error("Nested numeric child count mismatch")
    return Column(
        NumericColumn[dtype](
            values^, bitmap^, plan.nodes[plan.leaf_nodes[leaf]].name(), nulls
        )
    )


def _read_binary(
    mut file: FileHandle,
    metadata: FileMetadata,
    plan: _ReadPlan,
    leaf: Int,
    count: Int,
    arena_budget: Int,
    limits: PageLimits,
) raises -> Column:
    var node = metadata.schema[plan.leaves[leaf]].copy()
    var schema_node = plan.nodes[plan.leaf_nodes[leaf]].copy()
    var kind = schema_node.kind()
    var width = schema_node.fixed_width()
    var repeated = plan.repeated_def[leaf]
    var builder = BinaryBuilder(arena_budget, width)
    var bitmap = List[UInt8]()
    var bits = List[UInt8]()
    if kind == SchemaNode.BOOLEAN:
        bitmap.resize(_bitmap_bytes(count), 0)
        bits.resize(_bitmap_bytes(count), 0)
    var output = 0
    for group in metadata.row_groups:
        var col = group.columns[plan.columns[leaf]].copy()
        var cursor = _ColumnPages(
            col.copy(), group.num_rows, node.max_repetition_level, limits
        )
        var dictionary = BinaryColumn([0], [])
        var has_dictionary = False
        while True:
            var next = cursor.next(file)
            if not next:
                break
            var h = next.value().header
            var data = file.read_bytes(h.compressed_page_size)
            data = _page_body(data^, h, col.codec)
            if h.page_type == 2:
                if (
                    kind == SchemaNode.BOOLEAN
                    or (h.encoding != 0 and h.encoding != 2)
                    or h.num_values < 0
                    or h.num_values >= limits.max_page_bytes // 8
                ):
                    raise Error(
                        "Unsupported/oversized nested binary dictionary"
                    )
                dictionary = decode_plain_binary(
                    data,
                    h.num_values,
                    width,
                    limits.max_page_bytes - (h.num_values + 1) * 8,
                )
                has_dictionary = True
                continue
            var framing = _page_counts(data, h, node)
            var present = framing[1]
            var payload = List[UInt8]()
            payload.extend(Span(data)[framing[0] :])
            var levels = _NestedLevels(
                data, h, node.max_repetition_level, node.max_definition_level
            )
            var decoded = BinaryColumn([0], [])
            var booleans = BooleanColumn(0, [])
            var ids = _HybridDecoder(0, 0, 0, 0)
            var indexed = h.encoding == 2 or h.encoding == 8
            if kind == SchemaNode.BOOLEAN:
                if _bitmap_bytes(present) > limits.max_page_bytes:
                    raise Error("Boolean decoded page workspace exceeds budget")
                booleans = decode_boolean_values(payload, present, h.encoding)
            elif indexed:
                if not has_dictionary or len(payload) == 0:
                    raise Error("Nested binary dictionary/ID width missing")
                ids = _HybridDecoder(1, len(payload), Int(payload[0]), present)
            elif h.encoding == 0:
                if present >= limits.max_page_bytes // 8:
                    raise Error(
                        "Binary decoded page offsets exceed workspace budget"
                    )
                decoded = decode_plain_binary(
                    payload, present, width, limits.max_page_bytes
                )
            else:
                raise Error("Unsupported nested binary encoding")
            var used = 0
            for _ in range(h.num_values):
                var pair = levels.next(data)
                var definition = pair[1]
                if repeated >= 0 and definition < repeated:
                    continue
                if output >= count:
                    raise Error("Nested binary child count changed during read")
                var valid = definition == node.max_definition_level
                if kind == SchemaNode.BOOLEAN:
                    if valid:
                        bitmap[output // 8] |= UInt8(1) << UInt8(output % 8)
                        if booleans.value(used).value():
                            bits[output // 8] |= UInt8(1) << UInt8(output % 8)
                elif not valid:
                    builder.append_null()
                elif indexed:
                    var index = Int(ids.next(payload))
                    if index >= len(dictionary):
                        raise Error(
                            "Nested binary dictionary index out of range"
                        )
                    builder.append(dictionary.value(index))
                else:
                    builder.append(decoded.value(used))
                used += Int(valid)
                output += 1
            levels.finish()
            if indexed and kind != SchemaNode.BOOLEAN:
                ids.finish()
    if output != count:
        raise Error("Nested binary child count mismatch")
    if kind == SchemaNode.BOOLEAN:
        return Column(schema_node.name(), BooleanColumn(count, bits^, bitmap^))
    return Column(schema_node.name(), builder^.freeze())


def load_nested_table(
    path: String,
    var projection: Optional[List[List[String]]] = None,
    max_output_bytes: Int = 1073741824,
    page_limits: PageLimits = PageLimits(),
    metadata_limits: CompactLimits = CompactLimits(),
) raises -> NestedTable:
    """Select literal component paths, merging ancestors in source schema order.

    A terminal group selects all descendants. Traversal through LIST is not a
    child projection. The budget covers all retained offsets, validity and values;
    footer, bounded page/dictionary/codec workspaces are separate. Two passes
    validate levels/cardinalities before allocating final typed child buffers.
    """
    if max_output_bytes < 0:
        raise Error("Negative nested output budget")
    page_limits.validate()
    var file = open(path, "r")
    var envelope = _read_footer_bytes_from_file(file, path, metadata_limits)
    var footer_offset = envelope.offset
    var metadata = parse_metadata(envelope^.take_bytes(), metadata_limits)
    validate_file_ranges(metadata, footer_offset)
    var plan = _ReadPlan(metadata, projection^)
    var rows = Int(metadata.num_rows)
    var budget = max_output_bytes
    var states = List[_StructureState]()
    for node in plan.nodes:
        var state = _StructureState()
        if node.parent() >= 0 and (
            node.kind() == SchemaNode.GROUP or node.kind() == SchemaNode.LIST
        ):
            _charge(budget, _bitmap_bytes(rows))
            state.validity.resize(_bitmap_bytes(rows), 0)
            if node.kind() == SchemaNode.LIST:
                if rows >= budget // 8:
                    raise Error("Nested list offsets exceed output budget")
                _charge(budget, (rows + 1) * 8)
                state.offsets.resize(rows + 1, 0)
        states.append(state^)
    var counts = List[Int]()
    for i in range(len(plan.leaves)):
        var count = _scan_leaf(
            file, metadata, plan, i, states, budget, page_limits
        )
        _charge(
            budget,
            _leaf_overhead(
                plan.nodes[plan.leaf_nodes[i]].kind(), count, budget
            ),
        )
        counts.append(count)
    var columns = List[Column]()
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
    for i in range(len(plan.leaves)):
        var kind = plan.nodes[plan.leaf_nodes[i]].kind()
        if (
            kind == SchemaNode.BOOLEAN
            or kind == SchemaNode.BINARY
            or kind == SchemaNode.FIXED_BINARY
        ):
            var column = _read_binary(
                file, metadata, plan, i, counts[i], budget, page_limits
            )
            if kind != SchemaNode.BOOLEAN:
                _charge(budget, column.binary().byte_size())
            columns.append(column^)
        else:
            comptime for t in range(len(types)):
                if kind == SchemaNode.numeric_kind[types[t]]():
                    columns.append(
                        _read_numeric[types[t]](
                            file, metadata, plan, i, counts[i], page_limits
                        )
                    )
    var reversed_structures = List[NestedStructure]()
    while len(states) > 1:
        var i = len(states) - 1
        var state = states.pop()
        if (
            plan.nodes[i].kind() == SchemaNode.GROUP
            or plan.nodes[i].kind() == SchemaNode.LIST
        ):
            reversed_structures.append(state^.freeze(rows))
    var structures = List[NestedStructure]()
    while len(reversed_structures) > 0:
        structures.append(reversed_structures.pop())
    return NestedTable(plan^.take_schema(), columns^, structures^, rows)
