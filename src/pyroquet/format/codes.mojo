"""Parquet Thrift enum values used on the wire (parquet-format parquet.thrift).
"""


struct Encoding:
    """`Encoding` values for page payloads and levels."""

    comptime PLAIN = 0
    comptime PLAIN_DICTIONARY = 2
    comptime RLE = 3
    comptime BIT_PACKED = 4
    comptime DELTA_BINARY_PACKED = 5
    comptime DELTA_LENGTH_BYTE_ARRAY = 6
    comptime DELTA_BYTE_ARRAY = 7
    comptime RLE_DICTIONARY = 8
    comptime BYTE_STREAM_SPLIT = 9


struct PageType:
    """`PageType` values in `PageHeader.type`."""

    comptime DATA_PAGE = 0
    comptime INDEX_PAGE = 1
    comptime DICTIONARY_PAGE = 2
    comptime DATA_PAGE_V2 = 3


struct PageHeaderField:
    """`PageHeader` field ids of the page-type-specific header structs.

    Each equals `PageType` + 5, which the parser uses to cross-check them.
    """

    comptime DATA_PAGE = 5
    comptime INDEX_PAGE = 6
    comptime DICTIONARY_PAGE = 7
    comptime DATA_PAGE_V2 = 8


struct CompressionCodec:
    """`CompressionCodec` values in `ColumnMetaData.codec`."""

    comptime UNCOMPRESSED = 0
    comptime SNAPPY = 1
    comptime GZIP = 2
    comptime LZO = 3
    comptime BROTLI = 4
    comptime LZ4 = 5
    comptime ZSTD = 6
    comptime LZ4_RAW = 7
