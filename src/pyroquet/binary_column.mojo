"""Owned raw-byte columns with checked native-Int offsets and separate validity.

No text interpretation or UTF-8 validation is performed. Empty and null rows
both have zero bytes, distinguished by validity. A positive fixed_width enforces
FIXED_LEN_BYTE_ARRAY widths for present rows. Copies share immutable storage.
"""

from .storage import FrozenBuffer


struct BinaryColumn(Copyable, Movable, Sized):
    var _offsets: FrozenBuffer[Int]
    var _bytes: FrozenBuffer[UInt8]
    var _validity: FrozenBuffer[UInt8]
    var _null_count: Int
    var _fixed_width: Int

    def __init__(
        out self,
        var offsets: List[Int],
        var data: List[UInt8],
        var validity: List[UInt8] = List[UInt8](),
        fixed_width: Int = 0,
    ) raises:
        if fixed_width < 0:
            raise Error("Negative fixed binary width")
        if len(offsets) == 0 or offsets[0] != 0:
            raise Error("Binary offsets must begin at zero")
        var count = len(offsets) - 1
        if len(validity) != 0 and len(validity) != count // 8 + Int(
            count % 8 != 0
        ):
            raise Error("Binary validity length mismatch")
        if len(validity) != 0 and count % 8 != 0:
            if validity[len(validity) - 1] >> UInt8(count % 8) != 0:
                raise Error("Binary validity padding is nonzero")
        self._null_count = 0
        for i in range(count):
            if offsets[i + 1] < offsets[i] or offsets[i + 1] > len(data):
                raise Error("Binary offsets outside byte arena")
            var present = len(validity) == 0
            if not present:
                present = (validity[i // 8] & (UInt8(1) << UInt8(i % 8))) != 0
            var width = offsets[i + 1] - offsets[i]
            if not present:
                self._null_count += 1
                if width != 0:
                    raise Error("Null binary row must have zero bytes")
            elif fixed_width != 0 and width != fixed_width:
                raise Error("Fixed binary value width mismatch")
        if offsets[count] != len(data):
            raise Error("Binary terminal offset must equal arena size")
        self._offsets = FrozenBuffer(offsets^)
        self._bytes = FrozenBuffer(data^)
        self._validity = FrozenBuffer(validity^)
        self._fixed_width = fixed_width

    def __len__(self) -> Int:
        return len(self._offsets) - 1

    def null_count(self) -> Int:
        return self._null_count

    def byte_size(self) -> Int:
        return len(self._bytes)

    def fixed_width(self) -> Int:
        return self._fixed_width

    def is_valid(self, index: Int) raises -> Bool:
        if index < 0 or index >= len(self):
            raise Error("Binary row outside column")
        return (
            len(self._validity) == 0
            or (self._validity[index // 8] & (UInt8(1) << UInt8(index % 8)))
            != 0
        )

    def value(
        self, index: Int
    ) raises -> Span[UInt8, origin_of(self._bytes._owner)]:
        """Borrow a present raw value; null access raises instead of returning empty.
        """
        if not self.is_valid(index):
            raise Error("Cannot borrow a null binary value")
        var start = self._offsets[index]
        var end = self._offsets[index + 1]
        return self._bytes.view()[start:end]


struct BinaryBuilder(Movable, Sized):
    """Exclusive arena construction, capped before copying; freeze consumes builder.

    Offsets use native signed Int (64 bits on the supported platform). The byte
    budget must fit Int; count is limited so the terminal offset remains addressable.
    """

    var _offsets: List[Int]
    var _bytes: List[UInt8]
    var _validity: List[UInt8]
    var _limit: Int
    var _fixed_width: Int

    def __init__(
        out self,
        max_bytes: Int = 1073741824,
        fixed_width: Int = 0,
        byte_capacity: Int = 0,
    ) raises:
        if (
            max_bytes < 0
            or fixed_width < 0
            or byte_capacity < 0
            or byte_capacity > max_bytes
        ):
            raise Error("Negative binary storage limit or width")
        self._offsets = [0]
        self._bytes = List[UInt8](capacity=byte_capacity)
        self._validity = List[UInt8]()
        self._limit = max_bytes
        self._fixed_width = fixed_width

    def __len__(self) -> Int:
        return len(self._offsets) - 1

    def append(mut self, bytes: Span[UInt8, _]) raises:
        if self._fixed_width != 0 and len(bytes) != self._fixed_width:
            raise Error("Fixed binary value width mismatch")
        if len(bytes) > self._limit - len(self._bytes):
            raise Error("Binary byte budget exceeded")
        self._append_row(True)
        self._bytes.extend(bytes)
        self._offsets.append(len(self._bytes))

    def append_null(mut self) raises:
        self._append_row(False)
        self._offsets.append(len(self._bytes))

    def _append_row(mut self, present: Bool) raises:
        if len(self._offsets) >= Int.MAX // 8:
            raise Error("Binary offset allocation overflow")
        var row = len(self)
        if row % 8 == 0:
            self._validity.append(0)
        if present:
            self._validity[row // 8] |= UInt8(1) << UInt8(row % 8)

    def freeze(deinit self) raises -> BinaryColumn:
        return BinaryColumn(
            self._offsets^, self._bytes^, self._validity^, self._fixed_width
        )
