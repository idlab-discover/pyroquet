"""Initialized native storage with consuming freeze and shared immutable slices.

List owns allocation and initialized-length bookkeeping. Freezing transfers its
allocation into a shared owner; slicing retains that owner without copying data.
All range checks here remain enabled in optimized builds.
"""

from std.memory import ArcPointer


def _check_range(size: Int, offset: Int, length: Int) raises:
    if offset < 0 or length < 0 or offset > size or length > size - offset:
        raise Error("Buffer range outside initialized length")


struct FrozenBuffer[T: Copyable & Deinitable](Copyable, Movable, Sized):
    """Read-only storage handle. `copy` shares; `clone` copies logical values.
    """

    var _owner: ArcPointer[List[Self.T]]
    var _offset: Int
    var _length: Int

    def __init__(out self, var values: List[Self.T]):
        self._length = len(values)
        self._offset = 0
        self._owner = ArcPointer(values^)

    def __len__(self) -> Int:
        return self._length

    def __getitem__(self, index: Int) raises -> Self.T:
        _check_range(self._length, index, 1)
        return self._owner[][self._offset + index].copy()

    def slice(self, offset: Int, length: Int) raises -> Self:
        _check_range(self._length, offset, length)
        var result = self.copy()
        result._offset += offset
        result._length = length
        return result^

    def view(self) -> Span[Self.T, origin_of(self._owner)]:
        """Borrow initialized values; the compiler ties the view to this handle.
        """
        return Span[Self.T, origin_of(self._owner)](
            unsafe_ptr=self._owner[].unsafe_ptr().as_imm(),
            length=len(self._owner[]),
        )[self._offset : self._offset + self._length]

    def clone(self) -> Self:
        var values = List[Self.T]()
        values.reserve(self._length)
        for i in range(self._length):
            values.append(self._owner[][self._offset + i].copy())
        return Self(values^)


struct BufferBuilder[T: Copyable & Deinitable](Movable, Sized):
    """Exclusive mutable construction; only appended elements are initialized.
    """

    var _values: List[Self.T]

    def __init__(out self, capacity: Int = 0) raises:
        if capacity < 0:
            raise Error("Negative buffer capacity")
        self._values = List[Self.T]()
        self._values.reserve(capacity)

    def __len__(self) -> Int:
        return len(self._values)

    def append(mut self, var value: Self.T):
        self._values.append(value^)

    def freeze(deinit self) -> FrozenBuffer[Self.T]:
        return FrozenBuffer[Self.T](self._values^)
