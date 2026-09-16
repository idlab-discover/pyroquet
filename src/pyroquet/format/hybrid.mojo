"""Bounded Parquet RLE/bit-packed integers, excluding any framing prefix."""


struct _HybridDecoder(Movable):
    """Stream exactly count integers without allocating from wire run lengths.

    Call next with the same immutable byte buffer for each value, then finish.
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
    var _bit_pos: Int

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
        self._bit_pos = 0

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
            self._bit_pos = self._pos * 8
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

    def next(mut self, data: List[UInt8]) raises -> UInt32:
        if self._end > len(data):
            raise Error("hybrid stream exceeds buffer")
        if self._left == 0:
            raise Error("hybrid value count exhausted")
        if self._run_left == 0:
            self._start_run(data)
        var value = self._value
        if self._packed:
            # Read only overlapping bytes, including width-32 unaligned values.
            var bits_left = self._width
            var shift = 0
            value = 0
            while bits_left > 0:
                var offset = self._bit_pos % 8
                var take = min(bits_left, 8 - offset)
                var mask = (UInt32(1) << UInt32(take)) - 1
                value |= (
                    (UInt32(data[self._bit_pos // 8]) >> UInt32(offset)) & mask
                ) << UInt32(shift)
                self._bit_pos += take
                shift += take
                bits_left -= take
        self._run_left -= 1
        self._left -= 1
        return value

    def finish(self) raises:
        if self._left != 0:
            raise Error("hybrid stream has unconsumed values")
        if self._pos != self._end:
            raise Error("hybrid stream has trailing data")
        if self._run_left != 0 and (not self._packed or self._run_left > 7):
            raise Error("invalid hybrid final padding")
