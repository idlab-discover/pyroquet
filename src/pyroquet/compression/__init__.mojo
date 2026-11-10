"""Internal bounded Parquet codec seam; page framing stays with the caller."""
from mojo_snappy import (
    compress as snappy_compress,
    decompress as snappy_decompress,
    max_compressed_length as snappy_max_compressed_length,
)
from .gzip import decode_gzip, encode_gzip
from .zstd import decode_zstd, encode_zstd
from ..format.codes import CompressionCodec


def _check_start(data: List[UInt8], start: Int) raises:
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")


def validate_codec(codec: Int) raises:
    match codec:
        case (
            CompressionCodec.UNCOMPRESSED
            | CompressionCodec.SNAPPY
            | CompressionCodec.GZIP
            | CompressionCodec.ZSTD
        ):
            pass
        case _:
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
    match codec:
        case CompressionCodec.SNAPPY:
            _check_start(data, start)
            var decoded = snappy_decompress(
                data[start:], max_output_bytes=expected
            )
            if len(decoded) != expected:
                raise Error("Snappy decoded length mismatch")
            return decoded^
        case CompressionCodec.GZIP:
            return decode_gzip(data, expected, start)
        case CompressionCodec.ZSTD:
            return decode_zstd(data, expected, start)
        case _:
            raise Error("Expected a supported compressed codec")


def compress(
    codec: Int,
    data: List[UInt8],
    limit: Int,
    start: Int = 0,
    allow_expansion: Bool = False,
) raises -> List[UInt8]:
    """Encode a page section. V2 may stage bounded expansion before fallback."""
    match codec:
        case CompressionCodec.SNAPPY:
            var bound = limit
            if allow_expansion:
                bound = snappy_max_compressed_length(len(data) - start)
            _check_start(data, start)
            var encoded = snappy_compress(data[start:])
            if len(encoded) > bound:
                raise Error("Snappy encoded output exceeds limit")
            return encoded^
        case CompressionCodec.GZIP:
            return encode_gzip(data, limit, start, allow_expansion)
        case CompressionCodec.ZSTD:
            return encode_zstd(data, limit, start, allow_expansion)
        case _:
            raise Error("Expected a supported compressed codec")
