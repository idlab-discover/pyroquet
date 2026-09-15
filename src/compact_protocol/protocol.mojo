"""Checked Compact Protocol data primitives, independently usable from Parquet.

Readers consume an owned byte list. Writers collect a bounded metadata buffer.
After a decoding/encoding error, discard that instance; recovery is unsupported.
This is a wire codec, not a schema validator: callers match field types and read
the declared number of collection elements. Unknown fields use checked skip.
"""

from std.memory import bitcast


struct CompactType:
    comptime STOP = 0
    comptime TRUE = 1
    comptime FALSE = 2
    comptime BYTE = 3
    comptime I16 = 4
    comptime I32 = 5
    comptime I64 = 6
    comptime DOUBLE = 7
    comptime BINARY = 8
    comptime LIST = 9
    comptime SET = 10
    comptime MAP = 11
    comptime STRUCT = 12
    comptime UUID = 13


struct CompactLimits(ImplicitlyCopyable):
    var max_bytes: Int
    var max_binary_bytes: Int
    var max_collection_items: Int
    var max_depth: Int

    def __init__(
        out self,
        max_bytes: Int = 64 * 1024 * 1024,
        max_binary_bytes: Int = 16 * 1024 * 1024,
        max_collection_items: Int = 1_000_000,
        max_depth: Int = 64,
    ):
        self.max_bytes = max_bytes
        self.max_binary_bytes = max_binary_bytes
        self.max_collection_items = max_collection_items
        self.max_depth = max_depth

    def validate(self) raises:
        if (
            self.max_bytes < 0
            or self.max_binary_bytes < 0
            or self.max_collection_items < 0
            or self.max_depth < 1
        ):
            raise Error("Invalid Compact Protocol limits")


@fieldwise_init
struct FieldHeader(ImplicitlyCopyable):
    var field_id: Int
    var kind: Int

    def boolean(self) raises -> Bool:
        if self.kind != CompactType.TRUE and self.kind != CompactType.FALSE:
            raise Error("Compact field is not boolean")
        return self.kind == CompactType.TRUE


@fieldwise_init
struct CollectionHeader(ImplicitlyCopyable):
    var kind: Int
    var size: Int


@fieldwise_init
struct MapHeader(ImplicitlyCopyable):
    var key_kind: Int
    var value_kind: Int
    var size: Int


@fieldwise_init
struct _StructFrame(ImplicitlyCopyable):
    var last_id: Int
    var stopped: Bool


def _valid_kind(kind: Int) -> Bool:
    return kind >= CompactType.TRUE and kind <= CompactType.UUID


struct CompactReader(Movable):
    var _data: List[UInt8]
    var _pos: Int
    var _limits: CompactLimits
    var _frames: List[_StructFrame]

    def __init__(
        out self, var data: List[UInt8], limits: CompactLimits = CompactLimits()
    ) raises:
        limits.validate()
        if len(data) > limits.max_bytes:
            raise Error("Compact Protocol input exceeds byte limit")
        self._data = data^
        self._pos = 0
        self._limits = limits
        self._frames = List[_StructFrame]()

    def position(self) -> Int:
        return self._pos

    def remaining(self) -> Int:
        return len(self._data) - self._pos

    def _require(self, condition: Bool, message: String) raises:
        if not condition:
            raise Error(
                "Compact Protocol at byte " + String(self._pos) + ": " + message
            )

    def _byte(mut self) raises -> UInt8:
        self._require(self.remaining() > 0, "truncated input")
        var result = self._data[self._pos]
        self._pos += 1
        return result

    def _advance(mut self, count: Int) raises:
        self._require(
            count >= 0 and count <= self.remaining(), "truncated payload"
        )
        self._pos += count

    def _varint(mut self, bits: Int) raises -> UInt64:
        var result = UInt64(0)
        var count = (bits + 6) // 7
        for i in range(count):
            var byte = self._byte()
            var payload = UInt64(byte & 127)
            if i == count - 1:
                self._require(
                    payload < (UInt64(1) << UInt64(bits - i * 7)),
                    "integer overflow",
                )
            result |= payload << UInt64(i * 7)
            if (byte & 128) == 0:
                return result
        self._require(False, "unterminated or oversized varint")
        return 0

    def _integer(mut self, bits: Int) raises -> Int64:
        var raw = self._varint(bits)
        var sign = UInt64.MAX if (raw & 1) != 0 else UInt64(0)
        return bitcast[DType.int64]((raw >> 1) ^ sign)

    def read_byte(mut self) raises -> Int8:
        return bitcast[DType.int8](self._byte())

    def read_i16(mut self) raises -> Int16:
        return Int16(self._integer(16))

    def read_i32(mut self) raises -> Int32:
        return Int32(self._integer(32))

    def read_i64(mut self) raises -> Int64:
        return self._integer(64)

    def read_bool(mut self) raises -> Bool:
        """Read a collection boolean. Struct booleans live in FieldHeader."""
        var byte = self._byte()
        self._require(byte == 1 or byte == 2, "invalid boolean value")
        return byte == 1

    def read_double(mut self) raises -> Float64:
        var bits = UInt64(0)
        for i in range(8):
            bits |= UInt64(self._byte()) << UInt64(i * 8)
        return bitcast[DType.float64](bits)

    def _length(mut self, limit: Int) raises -> Int:
        var size = self._varint(32)
        self._require(
            size <= 2147483647 and size <= UInt64(limit), "length exceeds limit"
        )
        return Int(size)

    def _bytes(mut self, size: Int) raises -> List[UInt8]:
        self._require(size <= self.remaining(), "truncated payload")
        var result = List[UInt8]()
        result.reserve(size)
        for i in range(size):
            result.append(self._data[self._pos + i])
        self._pos += size
        return result^

    def read_binary(mut self) raises -> List[UInt8]:
        var size = self._length(self._limits.max_binary_bytes)
        return self._bytes(size)

    def read_string(mut self) raises -> String:
        var bytes = self.read_binary()
        return String(from_utf8=Span(bytes))

    def read_uuid(mut self) raises -> List[UInt8]:
        """Return 16 bytes in standard UUID network order, without reinterpretation.
        """
        return self._bytes(16)

    def begin_struct(mut self) raises:
        self._require(
            len(self._frames) < self._limits.max_depth,
            "struct depth exceeds limit",
        )
        self._frames.append(_StructFrame(0, False))

    def next_field(mut self) raises -> FieldHeader:
        self._require(len(self._frames) > 0, "field outside struct")
        var index = len(self._frames) - 1
        self._require(not self._frames[index].stopped, "field after STOP")
        var byte = self._byte()
        if byte == 0:
            self._frames[index].stopped = True
            return FieldHeader(0, CompactType.STOP)
        var kind = Int(byte & 15)
        self._require(_valid_kind(kind), "invalid field type")
        var delta = Int(byte >> 4)
        var field_id: Int
        if delta == 0:
            field_id = Int(self.read_i16())
        else:
            field_id = self._frames[index].last_id + delta
            self._require(field_id <= 32767, "field ID overflow")
        self._frames[index].last_id = field_id
        return FieldHeader(field_id, kind)

    def end_struct(mut self) raises:
        self._require(len(self._frames) > 0, "unbalanced struct end")
        self._require(
            self._frames[len(self._frames) - 1].stopped, "struct missing STOP"
        )
        _ = self._frames.pop()

    def read_collection(mut self) raises -> CollectionHeader:
        """List and set share this header. Callers consume exactly size elements.
        """
        var byte = self._byte()
        var kind = Int(byte & 15)
        var size = Int(byte >> 4)
        if size == 15:
            size = self._length(self._limits.max_collection_items)
        # Fastparquet emits STOP for empty lists; Apache Thrift also accepts it.
        # There are no element values to interpret in this compatibility case.
        self._require(
            _valid_kind(kind) or (kind == CompactType.STOP and size == 0),
            "invalid collection type",
        )
        self._require(
            size <= self._limits.max_collection_items,
            "collection exceeds limit",
        )
        return CollectionHeader(kind, size)

    def read_map(mut self) raises -> MapHeader:
        var size = self._length(self._limits.max_collection_items)
        if size == 0:
            return MapHeader(0, 0, 0)
        var byte = self._byte()
        var key_kind = Int(byte >> 4)
        var value_kind = Int(byte & 15)
        self._require(
            _valid_kind(key_kind) and _valid_kind(value_kind),
            "invalid map type",
        )
        return MapHeader(key_kind, value_kind, size)

    def skip_field(mut self, field: FieldHeader) raises:
        self._require(
            _valid_kind(field.kind), "cannot skip STOP or invalid type"
        )
        self._skip(field.kind, len(self._frames), True)

    def _skip(mut self, kind: Int, depth: Int, in_field: Bool) raises:
        if kind == CompactType.TRUE or kind == CompactType.FALSE:
            if not in_field:
                _ = self.read_bool()
        elif kind == CompactType.BYTE:
            self._advance(1)
        elif kind == CompactType.I16:
            _ = self.read_i16()
        elif kind == CompactType.I32:
            _ = self.read_i32()
        elif kind == CompactType.I64:
            _ = self.read_i64()
        elif kind == CompactType.DOUBLE:
            self._advance(8)
        elif kind == CompactType.BINARY:
            var size = self._length(self._limits.max_binary_bytes)
            self._advance(size)
        elif kind == CompactType.UUID:
            self._advance(16)
        elif kind == CompactType.STRUCT:
            self._require(
                depth < self._limits.max_depth, "skip nesting exceeds limit"
            )
            self.begin_struct()
            while True:
                var field = self.next_field()
                if field.kind == CompactType.STOP:
                    break
                self._skip(field.kind, depth + 1, True)
            self.end_struct()
        elif kind == CompactType.LIST or kind == CompactType.SET:
            self._require(
                depth < self._limits.max_depth, "skip nesting exceeds limit"
            )
            var header = self.read_collection()
            for _ in range(header.size):
                self._skip(header.kind, depth + 1, False)
        elif kind == CompactType.MAP:
            self._require(
                depth < self._limits.max_depth, "skip nesting exceeds limit"
            )
            var header = self.read_map()
            for _ in range(header.size):
                self._skip(header.key_kind, depth + 1, False)
                self._skip(header.value_kind, depth + 1, False)
        else:
            self._require(False, "invalid skip type")

    def finish(self) raises:
        self._require(len(self._frames) == 0, "unclosed struct")
        self._require(self.remaining() == 0, "trailing bytes")


struct CompactWriter(Movable):
    var _data: List[UInt8]
    var _limits: CompactLimits
    var _frames: List[Int]
    var _failed: Bool

    def __init__(out self, limits: CompactLimits = CompactLimits()) raises:
        limits.validate()
        self._data = List[UInt8]()
        self._limits = limits
        self._frames = List[Int]()
        self._failed = False

    def _require(mut self, condition: Bool, message: String) raises:
        if not condition:
            self._failed = True
            raise Error(
                "Compact Protocol output at byte "
                + String(len(self._data))
                + ": "
                + message
            )

    def _byte(mut self, byte: UInt8) raises:
        self._require(
            len(self._data) < self._limits.max_bytes, "byte limit exceeded"
        )
        self._data.append(byte)

    def _varint(mut self, var value: UInt64) raises:
        while value >= 128:
            self._byte(UInt8(value & 127) | 128)
            value >>= 7
        self._byte(UInt8(value))

    def write_i64(mut self, value: Int64) raises:
        var raw = bitcast[DType.uint64](value)
        var sign = UInt64.MAX if value < 0 else UInt64(0)
        self._varint((raw << 1) ^ sign)

    def write_i32(mut self, value: Int32) raises:
        self.write_i64(Int64(value))

    def write_i16(mut self, value: Int16) raises:
        self.write_i64(Int64(value))

    def write_byte(mut self, value: Int8) raises:
        self._byte(bitcast[DType.uint8](value))

    def write_bool(mut self, value: Bool) raises:
        """Write a collection boolean; use write_bool_field for struct fields.
        """
        self._byte(UInt8(1 if value else 2))

    def write_double(mut self, value: Float64) raises:
        var raw = bitcast[DType.uint64](value)
        for i in range(8):
            self._byte(UInt8((raw >> UInt64(i * 8)) & 255))

    def _length(mut self, size: Int, limit: Int) raises:
        self._require(
            size >= 0 and size <= 2147483647 and size <= limit,
            "length exceeds limit",
        )
        self._varint(UInt64(size))

    def write_binary(mut self, bytes: Span[UInt8, _]) raises:
        self._length(len(bytes), self._limits.max_binary_bytes)
        self._require(
            len(bytes) <= self._limits.max_bytes - len(self._data),
            "byte limit exceeded",
        )
        for byte in bytes:
            self._data.append(byte)

    def write_string(mut self, value: String) raises:
        self.write_binary(value.as_bytes())

    def write_uuid(mut self, bytes: Span[UInt8, _]) raises:
        self._require(len(bytes) == 16, "UUID requires 16 bytes")
        for byte in bytes:
            self._byte(byte)

    def begin_struct(mut self) raises:
        self._require(
            len(self._frames) < self._limits.max_depth,
            "struct depth exceeds limit",
        )
        self._frames.append(0)

    def write_field(mut self, field_id: Int, kind: Int) raises:
        self._require(len(self._frames) > 0, "field outside struct")
        self._require(
            field_id >= -32768 and field_id <= 32767, "field ID outside i16"
        )
        self._require(_valid_kind(kind), "invalid field type")
        var index = len(self._frames) - 1
        var delta = field_id - self._frames[index]
        if delta > 0 and delta <= 15:
            self._byte(UInt8((delta << 4) | kind))
        else:
            self._byte(UInt8(kind))
            self.write_i16(Int16(field_id))
        self._frames[index] = field_id

    def write_bool_field(mut self, field_id: Int, value: Bool) raises:
        self.write_field(
            field_id, CompactType.TRUE if value else CompactType.FALSE
        )

    def end_struct(mut self) raises:
        self._require(len(self._frames) > 0, "unbalanced struct end")
        self._byte(0)
        _ = self._frames.pop()

    def write_collection(mut self, kind: Int, size: Int) raises:
        self._require(_valid_kind(kind), "invalid collection type")
        self._require(
            size >= 0
            and size <= 2147483647
            and size <= self._limits.max_collection_items,
            "collection exceeds limit",
        )
        if size < 15:
            self._byte(UInt8((size << 4) | kind))
        else:
            self._byte(UInt8(240 | kind))
            self._varint(UInt64(size))

    def write_map(mut self, key_kind: Int, value_kind: Int, size: Int) raises:
        if size != 0:
            self._require(
                _valid_kind(key_kind) and _valid_kind(value_kind),
                "invalid map type",
            )
        self._length(size, self._limits.max_collection_items)
        if size != 0:
            self._byte(UInt8((key_kind << 4) | value_kind))

    def finish(deinit self) raises -> List[UInt8]:
        self._require(not self._failed, "writer failed previously")
        self._require(len(self._frames) == 0, "unclosed struct")
        return self._data^
