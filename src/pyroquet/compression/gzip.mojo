"""RFC 1952 streams through the Linux LP64 zlib C ABI, loaded only on use."""
from std.ffi import OwnedDLHandle, c_int, c_uint, c_ulong, c_char
from std.sys import size_of, align_of


@fieldwise_init
struct _ZStream(Copyable, Movable):
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
    comptime assert size_of[_ZStream]() == 112
    comptime assert align_of[_ZStream]() == 8
    var library = OwnedDLHandle("libz.so.1")
    var version = library.get_function[Pointer[c_char, ImmUntrackedOrigin]](
        "zlibVersion"
    )
    var flags = library.get_function[c_ulong]("zlibCompileFlags")
    # zlib encodes the sizes of uInt, uLong, pointers, and z_off_t in pairs.
    var abi_flags = flags()
    if (abi_flags & 63) != 41 or (abi_flags & ((1 << 10) | (1 << 17))) != 0:
        raise Error("Unsupported zlib C ABI")
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
