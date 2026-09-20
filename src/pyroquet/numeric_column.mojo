"""Shared numeric value storage with independent, immutable validity."""
from numojo.core.ndarray import NDArray


struct NumericColumn[dtype: DType](Movable):
    var _values: NDArray[Self.dtype]
    var _validity: List[UInt8]
    var _name: String
    var _null_count: Int

    def __init__(
        out self,
        var values: NDArray[Self.dtype],
        var validity: List[UInt8],
        var name: String,
        null_count: Int,
    ) raises:
        _check_numeric[Self.dtype]()
        if values.ndim != 1 or null_count < 0 or null_count > values.size:
            raise Error("Invalid numeric column shape/count")
        if values.strides[0] != 1:
            raise Error(
                "Numeric column requires contiguous unit-stride storage"
            )
        if len(validity) == 0:
            if null_count != 0:
                raise Error("Nulls require a validity bitmap")
        else:
            if len(validity) != values.size // 8 + Int(values.size % 8 != 0):
                raise Error("Invalid column validity length")
            var present = 0
            for byte in validity:
                for bit in range(8):
                    present += Int((byte >> UInt8(bit)) & 1)
            if values.size % 8 != 0:
                if (validity[len(validity) - 1] >> UInt8(values.size % 8)) != 0:
                    raise Error("Nonzero validity padding")
            if values.size - present != null_count:
                raise Error("Validity and null count disagree")
        self._values = values^
        self._validity = validity^
        self._name = name^
        self._null_count = null_count

    def values(self) -> ref[origin_of(self._values)] NDArray[Self.dtype]:
        """Borrow the handle; shared aliases can mutate its value allocation."""
        return self._values

    def values_mut(self) raises -> NDArray[Self.dtype]:
        """Return a retained shared handle for in-place NuMojo operations.

        Handle layout/reassignment is local; payload changes are visible to all
        aliases. Null payloads may change without changing validity. Callers must
        exclude concurrent mutation during reads and saves.
        """
        var handle = self._values.view_with_layout(
            self._values.shape, self._values.strides, self._values.offset
        )
        handle.flags.WRITEABLE = True
        return handle^

    def validity(self) -> Span[UInt8, origin_of(self._validity)]:
        """LSB-first packed validity; empty means all valid."""
        return Span(self._validity)

    def name(self) -> String:
        return self._name

    def size(self) -> Int:
        return self._values.size

    def null_count(self) -> Int:
        return self._null_count

    def value(self, index: Int) raises -> Optional[Scalar[Self.dtype]]:
        if index < 0 or index >= self.size():
            raise Error("Column index out of range")
        if len(self._validity) != 0 and not (
            self._validity[index // 8] & (UInt8(1) << UInt8(index % 8))
        ):
            return None
        return self._values.unsafe_ptr()[unsafe_offset=index]


def _check_numeric[dtype: DType]():
    comptime assert (
        dtype == DType.int8
        or dtype == DType.uint8
        or dtype == DType.int16
        or dtype == DType.uint16
        or dtype == DType.int32
        or dtype == DType.uint32
        or dtype == DType.int64
        or dtype == DType.uint64
        or dtype == DType.float16
        or dtype == DType.float32
        or dtype == DType.float64
    ), "Unsupported numeric dtype"
