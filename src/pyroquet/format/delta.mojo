"""Bounded streaming DELTA_BINARY_PACKED physical integer decoding.

Authority: parquet-format/Encodings.md, Delta Encoding: block/miniblock
parameters, arbitrary final padding, and two's-complement wrapping arithmetic.
No allocation depends on stream headers; the caller bounds the physical count.
"""


struct _DeltaDecoder[physical_bits: Int](Movable):
    var pos: Int
    var end: Int
    var remaining: Int
    var first: Bool
    var previous: UInt64
    var block_size: Int
    var miniblocks: Int
    var per_mini: Int
    var block_remaining: Int
    var widths: Int
    var mini_index: Int
    var mini_remaining: Int
    var mini_start: Int
    var mini_value: Int
    var width: Int
    var minimum: UInt64

    def __init__(
        out self, bytes: List[UInt8], start: Int, end: Int, count: Int
    ) raises:
        comptime assert Self.physical_bits == 32 or Self.physical_bits == 64
        if start < 0 or end < start or end > len(bytes) or count < 0:
            raise Error("Invalid delta payload bounds")
        self.pos = start
        self.end = end
        self.remaining = count
        self.first = True
        self.previous = 0
        self.block_size = 0
        self.miniblocks = 0
        self.per_mini = 0
        self.block_remaining = 0
        self.widths = 0
        self.mini_index = 0
        self.mini_remaining = 0
        self.mini_start = 0
        self.mini_value = 0
        self.width = 0
        self.minimum = 0
        # Null-only pages may omit the value stream entirely.
        if count == 0 and start == end:
            return
        var block = self._uleb(bytes, 32)
        var minis = self._uleb(bytes, 32)
        var total = self._uleb(bytes, 32)
        if (
            block == 0
            or block % 128 != 0
            or minis == 0
            or block % minis != 0
            or (block // minis) % 32 != 0
        ):
            raise Error("Invalid delta block/miniblock parameters")
        if total != UInt64(count):
            raise Error("Delta physical value count disagrees with levels")
        self.block_size = Int(block)
        self.miniblocks = Int(minis)
        self.per_mini = Int(block // minis)
        self.previous = self._signed_bits(bytes)

    def _uleb(mut self, bytes: List[UInt8], bits: Int) raises -> UInt64:
        var result = UInt64(0)
        var shift = 0
        while shift < bits:
            if self.pos >= self.end:
                raise Error("Truncated delta varint")
            var byte = bytes[self.pos]
            self.pos += 1
            var take = min(7, bits - shift)
            if UInt64(byte & 127) >= (UInt64(1) << UInt64(take)):
                raise Error("Delta varint overflow")
            result |= UInt64(byte & 127) << UInt64(shift)
            if byte & 128 == 0:
                return result
            shift += 7
        raise Error("Delta varint overflow")

    def _signed_bits(mut self, bytes: List[UInt8]) raises -> UInt64:
        var encoded = self._uleb(bytes, Self.physical_bits)
        return (encoded >> 1) ^ (UInt64(0) - (encoded & 1))

    def next(mut self, bytes: List[UInt8]) raises -> UInt64:
        if self.remaining <= 0 or self.end > len(bytes):
            raise Error("Delta value count exhausted or invalid source")
        if self.first:
            self.first = False
        else:
            if self.block_remaining == 0:
                self.minimum = self._signed_bits(bytes)
                if self.miniblocks > self.end - self.pos:
                    raise Error("Truncated delta miniblock widths")
                self.widths = self.pos
                self.pos += self.miniblocks
                self.mini_index = 0
                self.block_remaining = min(self.block_size, self.remaining)
            if self.mini_remaining == 0:
                self.width = Int(bytes[self.widths + self.mini_index])
                self.mini_index += 1
                if self.width > Self.physical_bits:
                    raise Error(
                        "Delta bit width exceeds physical integer width"
                    )
                # per_mini is a multiple of 32; multiply after division.
                var byte_count = (self.per_mini // 8) * self.width
                if byte_count > self.end - self.pos:
                    raise Error("Truncated delta miniblock")
                self.mini_start = self.pos
                self.pos += byte_count
                self.mini_value = 0
                self.mini_remaining = min(self.per_mini, self.block_remaining)
            var adjusted = UInt64(0)
            var bit_offset = self.mini_value * self.width
            for bit in range(self.width):
                var at = bit_offset + bit
                adjusted |= UInt64(
                    (bytes[self.mini_start + at // 8] >> UInt8(at % 8)) & 1
                ) << UInt64(bit)
            self.previous += self.minimum + adjusted
            self.mini_value += 1
            self.mini_remaining -= 1
            self.block_remaining -= 1
        self.remaining -= 1
        comptime if Self.physical_bits == 32:
            self.previous &= 0xFFFFFFFF
        return self.previous

    def finish(self) raises:
        if self.remaining != 0 or self.pos != self.end:
            raise Error("Missing delta values or trailing delta payload")
