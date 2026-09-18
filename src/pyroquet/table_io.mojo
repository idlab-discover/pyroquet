"""Flat scalar table loading with one validated footer and ordered projection.

All schema/chunk structure and local byte ranges are validated, including those
of unselected fields. Only selected columns have their pages and values decoded;
unselected unsupported types, encodings and codecs do not prevent projection.
"""
from compact_protocol import CompactLimits
from .format.footer import _read_footer_bytes_from_file
from .format.metadata import parse_metadata, validate_file_ranges
from .format.pages import PageLimits
from .numojo_io import _matches_numeric, _load_numeric_from_file
from .schema import Schema, SchemaNode
from .table import Table, Column
from .binary_io import _binary_kind, _binary_overhead, _load_binary_from_file
from std.sys import size_of


def load_table(
    path: String,
    var projection: Optional[List[String]] = None,
    max_output_bytes: Int = 1073741824,
    page_limits: PageLimits = PageLimits(),
    metadata_limits: CompactLimits = CompactLimits(),
) raises -> Table:
    """Load all fields, or literal names in the requested order.

    Missing/repeated selections raise. An explicit empty selection retains the
    file row count. The aggregate output budget covers selected values and packed
    validity, separately from bounded footer/page workspaces.
    """
    if max_output_bytes < 0:
        raise Error("Negative output budget")
    page_limits.validate()
    var file = open(path, "r")
    var envelope = _read_footer_bytes_from_file(file, path, metadata_limits)
    var footer_offset = envelope.offset
    var metadata = parse_metadata(envelope^.take_bytes(), metadata_limits)
    validate_file_ranges(metadata, footer_offset)
    var names = List[String]()
    if projection:
        names = projection.take()
    else:
        for node in metadata.schema:
            if node.parent == 0:
                names.append(node.name)
    var indices = List[Int]()
    var leaves = List[Int]()
    var selected_names = Dict[String, Bool]()
    for name in names:
        if name in selected_names:
            raise Error("Repeated projection name: " + name)
        selected_names[name] = True
        var selected = -1
        var leaf_index = 0
        for i in range(1, len(metadata.schema)):
            if (
                metadata.schema[i].parent == 0
                and metadata.schema[i].name == name
            ):
                selected = i
                leaves.append(leaf_index)
            if not metadata.schema[i].is_group():
                leaf_index += 1
        if selected == -1:
            raise Error("Top-level column not found: " + name)
        indices.append(selected)
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
    var budget = max_output_bytes
    # Preflight fixed output storage; charge variable arenas as they materialize.
    for index in indices:
        var matched = False
        comptime for t in range(len(types)):
            comptime dtype = types[t]
            if (
                _matches_numeric[dtype](metadata.schema[index])
                and metadata.schema[index].max_repetition_level == 0
            ):
                matched = True
                comptime width = size_of[Scalar[dtype]]()
                if metadata.num_rows > Int64(budget // width):
                    raise Error("Table exceeds aggregate output budget")
                var rows = Int(metadata.num_rows)
                budget -= rows * width
                if metadata.schema[index].nullable():
                    var bitmap = rows // 8 + Int(rows % 8 != 0)
                    if bitmap > budget:
                        raise Error(
                            "Table validity exceeds aggregate output budget"
                        )
                    budget -= bitmap
        var kind = _binary_kind(metadata.schema[index])
        if kind >= 0:
            budget -= _binary_overhead(Int(metadata.num_rows), kind, budget)
            matched = True
        if not matched:
            raise Error("Selected field is not a supported flat column")
    var nodes = List[SchemaNode]()
    nodes.append(SchemaNode("schema", SchemaNode.GROUP, -1))
    var columns = List[Column]()
    for i in range(len(indices)):
        var index = indices[i]
        var kind = _binary_kind(metadata.schema[index])
        if kind >= 0:
            var width = (
                metadata.schema[index].type_length if kind
                == SchemaNode.FIXED_BINARY else 0
            )
            nodes.append(
                SchemaNode(
                    names[i], kind, 0, metadata.schema[index].nullable(), width
                )
            )
            var overhead = _binary_overhead(
                Int(metadata.num_rows), kind, max_output_bytes
            )
            var column = _load_binary_from_file(
                file, metadata, index, leaves[i], budget + overhead, page_limits
            )
            if kind == SchemaNode.ENUM:
                # The empty label dictionary's terminal offset was preflighted.
                budget -= column.enumeration().dictionary_byte_size() - 8
            elif kind != SchemaNode.BOOLEAN:
                budget -= column._binary_storage().byte_size()
            columns.append(column^)
            continue
        comptime for t in range(len(types)):
            comptime dtype = types[t]
            if _matches_numeric[dtype](metadata.schema[index]):
                nodes.append(
                    SchemaNode(
                        names[i],
                        SchemaNode.numeric_kind[dtype](),
                        0,
                        metadata.schema[index].nullable(),
                    )
                )
                columns.append(
                    Column(
                        _load_numeric_from_file[dtype](
                            file,
                            metadata,
                            index,
                            leaves[i],
                            max_output_bytes,
                            page_limits,
                        )
                    )
                )
    return Table(Schema(nodes^), columns^, Int(metadata.num_rows))
