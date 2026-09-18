"""RFC 1952 streams through the Linux LP64 zlib C ABI, loaded only on use."""
from std.ffi import OwnedDLHandle, c_int, c_uint, c_ulong, c_char
from std.sys import size_of, align_of


@fieldwise_init
struct _ZStream(Movable):
    var next_in: OptionalPointer[UInt8, ImmUntrackedOrigin]
    var avail_in: c_uint
    var total_in: c_ulong
    var next_out: OptionalPointer[UInt8, MutUntrackedOrigin]
    var avail_out: c_uint
    var total_out: c_ulong
    var msg: OptionalPointer[UInt8, MutUntrackedOrigin]
    var state: OptionalPointer[UInt8, MutUntrackedOrigin]
    var zalloc: OptionalPointer[UInt8, MutUntrackedOrigin]
    var zfree: OptionalPointer[UInt8, MutUntrackedOrigin]
    var opaque: OptionalPointer[UInt8, MutUntrackedOrigin]
    var data_type: c_int
    var adler: c_ulong
    var reserved: c_ulong


def _library() raises -> OwnedDLHandle:
    comptime assert size_of[_ZStream]() == 112
    comptime assert align_of[_ZStream]() == 8
    var library = OwnedDLHandle("libz.so.1")
    var flags = library.get_function[c_ulong]("zlibCompileFlags")
    # zlib encodes the sizes of uInt, uLong, pointers, and z_off_t in pairs.
    var abi_flags = flags()
    if (abi_flags & 63) != 41 or (abi_flags & ((1 << 10) | (1 << 17))) != 0:
        raise Error("Unsupported zlib C ABI")
    return library^


def decode_gzip(
    data: List[UInt8], expected: Int, start: Int = 0
) raises -> List[UInt8]:
    if (
        expected < 0
        or expected > 2147483647
        or start < 0
        or start > len(data)
        or len(data) - start > 2147483647
    ):
        raise Error("Invalid GZIP section bounds")
    var library = _library()
    var version = library.get_function[Pointer[c_char, ImmUntrackedOrigin]](
        "zlibVersion"
    )
    var initialize = library.get_function[c_int]("inflateInit2_")
    var inflate = library.get_function[c_int]("inflate")
    var reset = library.get_function[c_int]("inflateReset2")
    var finish = library.get_function[c_int]("inflateEnd")
    var output = List[UInt8](length=expected, fill=0)
    var overflow = UInt8(0)
    var stream = _ZStream(
        None, 0, 0, None, 0, 0, None, None, None, None, None, 0, 0, 0
    )
    var pointer = Pointer(to=stream)
    if (
        initialize(pointer, c_int(31), version(), c_int(size_of[_ZStream]()))
        != 0
    ):
        raise Error("Cannot initialize GZIP decoder")
    var consumed = start
    var produced = 0
    try:
        while True:
            stream.next_in = (
                data.unsafe_ptr()
                .unsafe_offset(consumed)
                .unsafe_origin_cast[ImmUntrackedOrigin]()
            )
            stream.avail_in = c_uint(len(data) - consumed)
            if produced == expected:
                stream.next_out = Pointer(to=overflow).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                stream.avail_out = 1
            else:
                stream.next_out = (
                    output.unsafe_ptr()
                    .unsafe_offset(produced)
                    .unsafe_origin_cast[MutUntrackedOrigin]()
                )
                stream.avail_out = c_uint(expected - produced)
            var before_in = stream.avail_in
            var before_out = stream.avail_out
            var status = inflate(pointer, c_int(0))
            var used = Int(before_in - stream.avail_in)
            var written = Int(before_out - stream.avail_out)
            consumed += used
            if written > expected - produced:
                raise Error("GZIP output exceeds declared size")
            produced += written
            if status == 1:
                if consumed == len(data):
                    break
                if reset(pointer, c_int(31)) != 0:
                    raise Error("Cannot reset GZIP decoder")
            elif status != 0 or (used == 0 and written == 0):
                raise Error("Invalid, truncated or stalled GZIP stream")
        if produced != expected:
            raise Error("GZIP output differs from declared size")
    except err:
        _ = finish(pointer)
        raise err^
    if finish(pointer) != 0:
        raise Error("Cannot finalize GZIP decoder")
    return output^


def encode_gzip(
    data: List[UInt8], limit: Int, start: Int = 0, allow_expansion: Bool = False
) raises -> List[UInt8]:
    """Emit one GZIP member; V2 may stage up to zlib's checked bound.

    allow_expansion is for callers that discard non-beneficial compressed
    values. It does not relax the caller's stored-page limit.
    """
    if (
        start < 0
        or start > len(data)
        or len(data) - start > 2147483647
        or limit < 0
        or limit > 2147483647
    ):
        raise Error("Invalid GZIP compression bounds")
    var library = _library()
    var version = library.get_function[Pointer[c_char, ImmUntrackedOrigin]](
        "zlibVersion"
    )
    var initialize = library.get_function[c_int]("deflateInit2_")
    var deflate = library.get_function[c_int]("deflate")
    var bound = library.get_function[c_ulong]("deflateBound")
    var finish = library.get_function[c_int]("deflateEnd")
    var stream = _ZStream(
        None, 0, 0, None, 0, 0, None, None, None, None, None, 0, 0, 0
    )
    var pointer = Pointer(to=stream)
    # Default level/strategy, DEFLATED, GZIP-only wrapper, 32 KiB window,
    # memLevel=8. zlib owns its default allocator and frees it at deflateEnd.
    if (
        initialize(
            pointer,
            c_int(-1),
            c_int(8),
            c_int(31),
            c_int(8),
            c_int(0),
            version(),
            c_int(size_of[_ZStream]()),
        )
        != 0
    ):
        raise Error("Cannot initialize GZIP encoder")
    var output = List[UInt8]()
    var produced = 0
    try:
        var capacity = bound(pointer, c_ulong(len(data) - start))
        if capacity == 0 or capacity > c_ulong(4294967295):
            raise Error("GZIP staging bound exceeds C buffer limit")
        if not allow_expansion:
            capacity = min(capacity, c_ulong(limit))
        output.resize(Int(capacity), fill=0)
        var consumed = start
        while True:
            stream.next_in = (
                data.unsafe_ptr()
                .unsafe_offset(consumed)
                .unsafe_origin_cast[ImmUntrackedOrigin]()
            )
            stream.avail_in = c_uint(len(data) - consumed)
            stream.next_out = (
                output.unsafe_ptr()
                .unsafe_offset(produced)
                .unsafe_origin_cast[MutUntrackedOrigin]()
            )
            stream.avail_out = c_uint(Int(capacity) - produced)
            var before_in = stream.avail_in
            var before_out = stream.avail_out
            var status = deflate(pointer, c_int(4))
            var used = Int(before_in - stream.avail_in)
            var written = Int(before_out - stream.avail_out)
            consumed += used
            produced += written
            if status == 1:
                if consumed != len(data):
                    raise Error("GZIP encoder left unconsumed input")
                break
            if (
                status != 0
                or produced == Int(capacity)
                or (used == 0 and written == 0)
            ):
                raise Error("GZIP compression failed or exceeds page limit")
    except err:
        _ = finish(pointer)
        raise err^
    if finish(pointer) != 0:
        raise Error("Cannot finalize GZIP encoder")
    output.resize(produced, fill=0)
    return output^
