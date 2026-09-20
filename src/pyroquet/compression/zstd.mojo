"""Bounded Zstandard frames through the Linux LP64 C ABI, loaded on use."""
from std.ffi import OwnedDLHandle, c_int, c_uint, c_ulong
from std.sys import size_of


def _library() raises -> OwnedDLHandle:
    comptime assert size_of[c_ulong]() == 8
    comptime assert size_of[Int]() == 8
    return OwnedDLHandle("libzstd.so.1")


def decode_zstd(
    data: List[UInt8], expected: Int, start: Int = 0
) raises -> List[UInt8]:
    """Decode complete concatenated frames to exactly the declared size.

    The simple C API owns and frees its context, including on failure. Its
    destination capacity bounds output independently of untrusted frame sizes.
    The caller checks its page budget before entering this codec seam.
    """
    if (
        expected < 0
        or expected > 2147483647
        or start < 0
        or start >= len(data)
        or len(data) - start > 2147483647
    ):
        raise Error("Invalid ZSTD section bounds")
    var library = _library()
    var decode = library.get_function[c_ulong]("ZSTD_decompress")
    var is_error = library.get_function[c_uint]("ZSTD_isError")
    var output = List[UInt8](length=expected, fill=0)
    var size = decode(
        output.unsafe_ptr(),
        c_ulong(expected),
        data.unsafe_ptr().unsafe_offset(start),
        c_ulong(len(data) - start),
    )
    if is_error(size) != 0 or size != c_ulong(expected):
        raise Error("Invalid, truncated or incorrectly sized ZSTD stream")
    return output^


def encode_zstd(
    data: List[UInt8], limit: Int, start: Int = 0, allow_expansion: Bool = False
) raises -> List[UInt8]:
    """Emit one frame; V2 may stage bounded expansion before raw fallback."""
    if (
        start < 0
        or start > len(data)
        or len(data) - start > 2147483647
        or limit < 0
        or limit > 2147483647
    ):
        raise Error("Invalid ZSTD compression bounds")
    var library = _library()
    var bound = library.get_function[c_ulong]("ZSTD_compressBound")
    var encode = library.get_function[c_ulong]("ZSTD_compress")
    var is_error = library.get_function[c_uint]("ZSTD_isError")
    var capacity = bound(c_ulong(len(data) - start))
    if is_error(capacity) != 0 or capacity > c_ulong(4294967295):
        raise Error("ZSTD staging bound exceeds buffer limit")
    if not allow_expansion:
        capacity = min(capacity, c_ulong(limit))
    var output = List[UInt8](length=Int(capacity), fill=0)
    var size = encode(
        output.unsafe_ptr(),
        capacity,
        data.unsafe_ptr().unsafe_offset(start),
        c_ulong(len(data) - start),
        c_int(3),
    )
    if is_error(size) != 0:
        raise Error("ZSTD compression failed or exceeds page limit")
    output.resize(Int(size), fill=0)
    return output^
