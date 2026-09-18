"""Flat Boolean, raw binary and validated UTF-8 string materialization."""

from std.io.file import FileHandle
from .format.metadata import FileMetadata, SchemaElement
from .format.pages import PageLimits, PageHeader, _ColumnPages
from .format.hybrid import _HybridDecoder
from .format.binary_values import decode_plain_binary
from .format.boolean_values import decode_boolean_values
from .format.flat_pages import _page_body, _flat_page_values
from .binary_column import BinaryColumn, BinaryBuilder
from .string_column import StringColumn, _validate_string_binary
from .boolean_column import BooleanColumn
from .table import Column
from .schema import SchemaNode


def _binary_kind(node: SchemaElement) -> Int:
    if node.parent != 0 or node.max_repetition_level != 0:
        return -1
    # LogicalType is authoritative; ConvertedType is a legacy fallback only.
    if node.logical_type == 1 or (
        node.logical_type == -1 and node.converted_type == 0
    ):
        return SchemaNode.STRING if node.physical_type == 6 else -1
    if node.logical_type != -1 or node.converted_type != -1:
        return -1
    if node.physical_type == 0:
        return SchemaNode.BOOLEAN
    if node.physical_type == 6:
        return SchemaNode.BINARY
    if node.physical_type == 7 and node.type_length > 0:
        return SchemaNode.FIXED_BINARY
    return -1


def _load_binary_from_file(
    mut file: FileHandle,
    metadata: FileMetadata,
    selected: Int,
    column_index: Int,
    max_output_bytes: Int,
    page_limits: PageLimits,
) raises -> Column:
    var node = metadata.schema[selected].copy()
    var kind = _binary_kind(node)
    if kind < 0 or max_output_bytes < 0:
        raise Error("Unsupported Boolean/binary schema or output budget")
    var rows = Int(metadata.num_rows)
    var overhead = _binary_overhead(rows, kind, max_output_bytes)
    var bitmap_size = rows // 8 + Int(rows % 8 != 0)
    var validity = List[UInt8]()
    validity.resize(bitmap_size, 0)
    var bits = List[UInt8]()
    if kind == SchemaNode.BOOLEAN:
        bits.resize(bitmap_size, 0)
    var width = node.type_length if kind == SchemaNode.FIXED_BINARY else 0
    var builder = BinaryBuilder(max_output_bytes - overhead, width)
    var output = 0
    for group in metadata.row_groups:
        var dictionary = BinaryColumn([0], [])
        var has_dictionary = False
        var cursor = _ColumnPages(
            group.columns[column_index].copy(), group.num_rows, 0, page_limits
        )
        while True:
            var next = cursor.next(file)
            if not next:
                break
            var page = next.value()
            var h = page.header
            var data = file.read_bytes(h.compressed_page_size)
            data = _page_body(data^, h, group.columns[column_index].codec)
            if h.page_type == 2:
                if kind == SchemaNode.BOOLEAN or (
                    h.encoding != 0 and h.encoding != 2
                ):
                    raise Error("Unsupported dictionary encoding/type")
                # Include offsets as well as bytes in the dictionary arena budget.
                if (
                    h.num_values < 0
                    or h.num_values >= page_limits.max_page_bytes // 8
                ):
                    raise Error("Binary dictionary offset budget exceeded")
                dictionary = decode_plain_binary(
                    data,
                    h.num_values,
                    width,
                    page_limits.max_page_bytes - (h.num_values + 1) * 8,
                )
                if kind == SchemaNode.STRING:
                    _validate_string_binary(dictionary)
                has_dictionary = True
                continue
            if h.num_values < 0 or h.num_values > rows - output:
                raise Error("Data page exceeds output rows")
            var framing = _flat_page_values(
                data, h, node.nullable(), validity, output
            )
            var start = framing[0]
            var present = framing[1]
            if not node.nullable():
                for i in range(h.num_values):
                    var row = output + i
                    validity[row // 8] |= UInt8(1) << UInt8(row % 8)
            var payload = List[UInt8]()
            payload.reserve(len(data) - start)
            for i in range(start, len(data)):
                payload.append(data[i])
            if kind == SchemaNode.BOOLEAN:
                var decoded = decode_boolean_values(
                    payload, present, h.encoding
                )
                var used = 0
                for i in range(h.num_values):
                    var row = output + i
                    if validity[row // 8] & (UInt8(1) << UInt8(row % 8)):
                        if decoded.value(used).value():
                            bits[row // 8] |= UInt8(1) << UInt8(row % 8)
                        used += 1
            else:
                var indexed = h.encoding == 2 or h.encoding == 8
                var decoded = BinaryColumn([0], [])
                var ids = _HybridDecoder(0, 0, 0, 0)
                if indexed:
                    if not has_dictionary or len(payload) == 0:
                        raise Error("Missing binary dictionary or ID bit width")
                    ids = _HybridDecoder(
                        1, len(payload), Int(payload[0]), present
                    )
                elif h.encoding == 0:
                    decoded = decode_plain_binary(
                        payload, present, width, page_limits.max_page_bytes
                    )
                else:
                    raise Error("Unsupported binary value encoding")
                var used = 0
                for i in range(h.num_values):
                    var row = output + i
                    if validity[row // 8] & (UInt8(1) << UInt8(row % 8)):
                        if indexed:
                            var index = Int(ids.next(payload))
                            if index >= len(dictionary):
                                raise Error("Binary dictionary ID out of range")
                            builder.append(dictionary.value(index))
                        else:
                            builder.append(decoded.value(used))
                        used += 1
                    else:
                        builder.append_null()
                if indexed:
                    ids.finish()
            output += h.num_values
    if output != rows:
        raise Error("Decoded binary row count mismatch")
    if kind == SchemaNode.BOOLEAN:
        return Column(node.name.copy(), BooleanColumn(rows, bits^, validity^))
    if kind == SchemaNode.STRING:
        return Column(node.name.copy(), StringColumn(builder^.freeze()))
    return Column(node.name.copy(), builder^.freeze())


def _binary_overhead(rows: Int, kind: Int, max_output_bytes: Int) raises -> Int:
    if rows < 0 or max_output_bytes < 0:
        raise Error("Invalid binary budget")
    var bitmap_size = rows // 8 + Int(rows % 8 != 0)
    var overhead = bitmap_size
    if kind == SchemaNode.BOOLEAN:
        if bitmap_size > max_output_bytes - overhead:
            raise Error("Boolean output budget exceeded")
        overhead += bitmap_size
    else:
        if (
            overhead > max_output_bytes
            or rows >= (max_output_bytes - overhead) // 8
        ):
            raise Error("Binary offset output budget exceeded")
        overhead += (rows + 1) * 8
    if overhead > max_output_bytes:
        raise Error("Binary output budget exceeded")
    return overhead
