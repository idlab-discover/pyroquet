"""Bounded Parquet RLE/bit-packed integers, excluding any framing prefix."""
from std.sys.info import is_little_endian


struct _HybridDecoder(Movable):
    """Stream exactly count integers without allocating from wire run lengths.

    Call next or next_batch with the same immutable byte buffer, then finish.
    Only a final packed group may contain up to seven unused values. Framing
    (dictionary width byte or V1 level length) belongs to the caller.
    """

    var _pos: Int
    var _end: Int
    var _width: Int
    var _left: Int
    var _run_left: Int
    var _packed: Bool
    var _value: UInt32
    var _byte_pos: Int
    var _buffer: UInt64
    var _bits: Int

    def __init__(
        out self, start: Int, end: Int, bit_width: Int, count: Int
    ) raises:
        if (
            start < 0
            or end < start
            or bit_width < 0
            or bit_width > 32
            or count < 0
        ):
            raise Error("invalid hybrid stream bounds, width or count")
        self._pos = start
        self._end = end
        self._width = bit_width
        self._left = count
        self._run_left = 0
        self._packed = False
        self._value = 0
        self._byte_pos = 0
        self._buffer = 0
        self._bits = 0

    def _start_run(mut self, data: List[UInt8]) raises:
        var header = UInt32(0)
        var done = False
        for i in range(5):
            if self._pos >= self._end:
                raise Error("truncated hybrid run header")
            var byte = data[self._pos]
            self._pos += 1
            if i == 4 and byte > 15:
                raise Error("overflowing hybrid run header")
            header |= UInt32(byte & 127) << UInt32(i * 7)
            if byte & 128 == 0:
                done = True
                break
        if not done:
            raise Error("overflowing hybrid run header")
        var length = Int(header >> 1)
        if length == 0:
            raise Error("empty hybrid run")
        self._packed = header & 1 != 0
        if self._packed:
            if length > 2147483647 // 8:
                raise Error("overflowing hybrid packed run length")
            self._run_left = length * 8
            if self._run_left > self._left and self._run_left - self._left > 7:
                raise Error("hybrid packed run exceeds value count")
            # One group of eight values occupies exactly width bytes.
            var size = length * self._width
            if size > self._end - self._pos:
                raise Error("truncated hybrid packed run")
            self._byte_pos = self._pos
            self._buffer = 0
            self._bits = 0
            self._pos += size
            if self._run_left > self._left and self._pos != self._end:
                raise Error("hybrid padding precedes trailing data")
        else:
            if length > self._left:
                raise Error("hybrid RLE run exceeds value count")
            self._run_left = length
            var size = (self._width + 7) // 8
            if size > self._end - self._pos:
                raise Error("truncated hybrid repeated value")
            self._value = 0
            for i in range(size):
                self._value |= UInt32(data[self._pos + i]) << UInt32(8 * i)
            self._pos += size
            if self._width < 32 and (self._value >> UInt32(self._width)) != 0:
                raise Error("hybrid repeated value exceeds bit width")

    def _prepare(mut self, data: List[UInt8]) raises:
        if self._end > len(data):
            raise Error("hybrid stream exceeds buffer")
        if self._left == 0:
            raise Error("hybrid value count exhausted")
        if self._run_left == 0:
            self._start_run(data)

    # Preserve inlining of the packed extraction formerly inside next.
    @always_inline
    def _packed_value(mut self, data: List[UInt8]) -> UInt32:
        var value = self._buffer
        if self._bits < self._width:
            var low = self._bits
            if is_little_endian() and self._pos - self._byte_pos >= 8:
                self._buffer = (
                    data.unsafe_ptr()
                    .unsafe_offset(self._byte_pos)
                    .unsafe_bitcast[UInt64]()
                    .unsafe_load[alignment=1]()
                )
                self._byte_pos += 8
                self._bits = 64
            else:
                self._buffer = 0
                self._bits = 0
                # _start_run validated the complete packed payload. Do not
                # read a following run or outside this bounded substream.
                while self._byte_pos < self._pos and self._bits < 56:
                    self._buffer |= UInt64(data[self._byte_pos]) << UInt64(
                        self._bits
                    )
                    self._byte_pos += 1
                    self._bits += 8
            var take = self._width - low
            value |= self._buffer << UInt64(low)
            self._buffer >>= UInt64(take)
            self._bits -= take
        else:
            self._buffer >>= UInt64(self._width)
            self._bits -= self._width
        return UInt32(value & ((UInt64(1) << UInt64(self._width)) - 1))

    @always_inline
    def next(mut self, data: List[UInt8]) raises -> UInt32:
        self._prepare(data)
        var value = self._value
        if self._packed:
            value = self._packed_value(data)
        self._run_left -= 1
        self._left -= 1
        return value

    def next_batch[
        O: MutOrigin
    ](
        mut self,
        data: List[UInt8],
        destination: Span[UInt32, O],
        limit: Int,
    ) raises -> Tuple[Int, Bool]:
        """Consume one run portion, returning (count, repeated).

        Repeated batches put one ID in destination[0] and may consume up to
        limit values. Packed batches write count IDs, bounded by limit, the
        destination length and 64. No allocation depends on a wire run length.
        Scalar and batch calls may be interleaved without alignment constraints.
        """
        if limit <= 0 or len(destination) == 0:
            raise Error("hybrid batch requires positive capacity and limit")
        self._prepare(data)
        var count = min(limit, min(self._left, self._run_left))
        if self._packed:
            count = min(count, min(len(destination), 64))
            for i in range(count):
                destination[i] = self._packed_value(data)
        else:
            destination[0] = self._value
        self._run_left -= count
        self._left -= count
        return (count, not self._packed)

    def finish(self) raises:
        if self._left != 0:
            raise Error("hybrid stream has unconsumed values")
        if self._pos != self._end:
            raise Error("hybrid stream has trailing data")
        if self._run_left != 0 and (not self._packed or self._run_left > 7):
            raise Error("invalid hybrid final padding")
