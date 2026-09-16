"""Packed immutable Boolean values with independent LSB-first validity."""

from .storage import FrozenBuffer


struct BooleanColumn(Copyable, Movable, Sized):
    var _values: FrozenBuffer[UInt8]
    var _validity: FrozenBuffer[UInt8]
    var _count: Int
    var _null_count: Int

    def __init__(
        out self,
        count: Int,
        var values: List[UInt8],
        var validity: List[UInt8] = List[UInt8](),
    ) raises:
        if count < 0:
            raise Error("Negative Boolean row count")
        var size = count // 8 + Int(count % 8 != 0)
        if len(values) != size or (
            len(validity) != 0 and len(validity) != size
        ):
            raise Error("Boolean bitmap length mismatch")
        if count % 8 != 0:
            if values[size - 1] >> UInt8(count % 8) != 0:
                raise Error("Boolean value padding is nonzero")
            if (
                len(validity) != 0
                and validity[size - 1] >> UInt8(count % 8) != 0
            ):
                raise Error("Boolean validity padding is nonzero")
        self._null_count = 0
        if len(validity) != 0:
            for i in range(count):
                if (validity[i // 8] & (UInt8(1) << UInt8(i % 8))) == 0:
                    self._null_count += 1
                    values[i // 8] &= ~(UInt8(1) << UInt8(i % 8))
        self._values = FrozenBuffer(values^)
        self._validity = FrozenBuffer(validity^)
        self._count = count

    def __len__(self) -> Int:
        return self._count

    def null_count(self) -> Int:
        return self._null_count

    def value(self, index: Int) raises -> Optional[Bool]:
        if index < 0 or index >= self._count:
            raise Error("Boolean row outside column")
        var mask = UInt8(1) << UInt8(index % 8)
        if (
            len(self._validity) != 0
            and (self._validity[index // 8] & mask) == 0
        ):
            return None
        return (self._values[index // 8] & mask) != 0
