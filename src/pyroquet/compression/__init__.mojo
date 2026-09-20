"""Internal bounded Parquet codec seam; page framing stays with the caller."""
from mojo_snappy import (
    decode_snappy,
    encode_snappy,
    snappy_max_compressed_length,
)
from .gzip import decode_gzip, encode_gzip
from .zstd import decode_zstd, encode_zstd


def validate_codec(codec: Int) raises:
    if codec != 0 and codec != 1 and codec != 2 and codec != 6:
        raise Error(
            "Only UNCOMPRESSED, SNAPPY, GZIP and ZSTD columns are supported"
        )


def decompress(
    codec: Int, data: List[UInt8], expected: Int, start: Int = 0
) raises -> List[UInt8]:
    """Decode a compressed section to exactly its declared size.

    The caller applies page budgets before this allocation. Codec workspace
    is transient and separate from page/retained column output budgets.
    """
    if codec == 1:
        return decode_snappy(data, expected, start)
    if codec == 2:
        return decode_gzip(data, expected, start)
    if codec == 6:
        return decode_zstd(data, expected, start)
    raise Error("Expected a supported compressed codec")


def compress(
    codec: Int,
    data: List[UInt8],
    limit: Int,
    start: Int = 0,
    allow_expansion: Bool = False,
) raises -> List[UInt8]:
    """Encode a page section. V2 may stage bounded expansion before fallback."""
    if codec == 1:
        var bound = limit
        if allow_expansion:
            bound = snappy_max_compressed_length(len(data) - start)
        return encode_snappy(data, bound, start)
    if codec == 2:
        return encode_gzip(data, limit, start, allow_expansion)
    if codec == 6:
        return encode_zstd(data, limit, start, allow_expansion)
    raise Error("Expected a supported compressed codec")
