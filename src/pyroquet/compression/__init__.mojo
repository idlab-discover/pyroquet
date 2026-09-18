"""Internal bounded Parquet codec seam; page framing stays with the caller."""
from mojo_snappy import decode_snappy
from .gzip import decode_gzip


def validate_codec(codec: Int) raises:
    if codec != 0 and codec != 1 and codec != 2:
        raise Error("Only UNCOMPRESSED, SNAPPY and GZIP columns are supported")


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
    raise Error("Expected a supported compressed codec")
