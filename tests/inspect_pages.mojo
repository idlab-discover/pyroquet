"""Page-header oracle probe. Arguments: FILE ROW_GROUP COLUMN."""
from std.sys import argv
from pyroquet.format import inspect_column_pages, PageLimits


def main() raises:
    var args = argv()
    var limits = PageLimits()
    if len(args) > 4:
        limits.max_pages_per_chunk = Int(args[4])
    var pages = inspect_column_pages(
        args[1], Int(args[2]), Int(args[3]), limits
    )
    for p in pages:
        var h = p.header
        print(
            p.offset,
            p.payload_offset,
            p.next_offset,
            h.page_type,
            h.uncompressed_page_size,
            h.compressed_page_size,
            h.header_size,
            Int(h.has_crc),
            h.crc,
            h.num_values,
            h.encoding,
            h.definition_level_encoding,
            h.repetition_level_encoding,
            h.num_nulls,
            h.num_rows,
            h.definition_levels_byte_length,
            h.repetition_levels_byte_length,
            Int(h.is_compressed),
            Int(h.has_is_sorted),
            Int(h.is_sorted),
        )
