"""Line-oriented inspection probe for independent metadata comparisons."""
from std.sys import argv
from pyroquet.format.metadata import inspect_metadata


def main() raises:
    var args = argv()
    var m = inspect_metadata(args[1])
    print(m.version, m.num_rows, len(m.schema), len(m.row_groups))
    for node in m.schema:
        print(
            "S",
            node.parent,
            node.physical_type,
            node.repetition,
            node.num_children,
            node.converted_type,
            node.logical_type,
            node.integer_width,
            Int(node.integer_signed),
            node.max_definition_level,
            node.max_repetition_level,
            node.name,
        )
        print("L", node.type_length)
    for group in m.row_groups:
        print(
            "R",
            group.num_rows,
            group.total_byte_size,
            group.total_compressed_size,
            group.file_offset,
        )
        for col in group.columns:
            print(
                "C",
                col.schema_index,
                col.physical_type,
                col.codec,
                col.num_values,
                col.data_page_offset,
                col.dictionary_page_offset,
                col.total_compressed_size,
                col.total_uncompressed_size,
            )
            print(
                "A",
                col.file_offset,
                col.index_page_offset,
                col.offset_index_offset,
                col.offset_index_length,
                col.column_index_offset,
                col.column_index_length,
                col.bloom_filter_offset,
                col.bloom_filter_length,
            )
            for part in col.path:
                print("P", part)
            for encoding in col.encodings:
                print("E", encoding)
