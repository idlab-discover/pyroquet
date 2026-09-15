from std.memory import bitcast
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from compact_protocol import (
    CompactReader,
    CompactWriter,
    CompactLimits,
    CompactType,
    FieldHeader,
)


def literal_struct() -> List[UInt8]:
    # {1: i32(42), 2: false, 3: binary(a\0\xff), 20: {1: true}, 21: i32(-1)}
    return [
        0x15,
        0x54,
        0x12,
        0x18,
        3,
        97,
        0,
        255,
        0x0C,
        0x28,
        0x11,
        0,
        0x15,
        1,
        0,
    ]


def skip_struct(
    var bytes: List[UInt8], limits: CompactLimits = CompactLimits()
) raises:
    var reader = CompactReader(bytes^, limits)
    reader.begin_struct()
    while True:
        var field = reader.next_field()
        if field.kind == CompactType.STOP:
            break
        reader.skip_field(field)
    reader.end_struct()
    reader.finish()


def test_literal_fields_and_nested_id_reset() raises:
    var reader = CompactReader(literal_struct())
    reader.begin_struct()
    var field = reader.next_field()
    assert_equal(field.field_id, 1)
    assert_equal(field.kind, CompactType.I32)
    assert_equal(reader.read_i32(), Int32(42))
    field = reader.next_field()
    assert_true(not field.boolean())
    field = reader.next_field()
    assert_equal(reader.read_binary(), [UInt8(97), 0, 255])
    field = reader.next_field()
    assert_equal(field.field_id, 20)
    reader.skip_field(field)
    field = reader.next_field()
    assert_equal(field.field_id, 21)
    assert_equal(reader.read_i32(), Int32(-1))
    assert_equal(reader.next_field().kind, CompactType.STOP)
    reader.end_struct()
    reader.finish()

    var writer = CompactWriter()
    writer.begin_struct()
    writer.write_field(1, CompactType.I32)
    writer.write_i32(42)
    writer.write_bool_field(2, False)
    writer.write_field(3, CompactType.BINARY)
    var bytes: List[UInt8] = [97, 0, 255]
    writer.write_binary(Span(bytes))
    writer.write_field(20, CompactType.STRUCT)
    writer.begin_struct()
    writer.write_bool_field(1, True)
    writer.end_struct()
    writer.write_field(21, CompactType.I32)
    writer.write_i32(-1)
    writer.end_struct()
    assert_equal(writer^.finish(), literal_struct())


def test_integer_extrema_and_signed_byte() raises:
    var writer = CompactWriter()
    writer.write_i16(Int16.MIN)
    writer.write_i16(Int16.MAX)
    writer.write_i32(Int32.MIN)
    writer.write_i32(Int32.MAX)
    writer.write_i64(Int64.MIN)
    writer.write_i64(Int64.MAX)
    writer.write_byte(-128)
    var expected: List[UInt8] = [
        255,
        255,
        3,
        254,
        255,
        3,
        255,
        255,
        255,
        255,
        15,
        254,
        255,
        255,
        255,
        15,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        1,
        254,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        1,
        128,
    ]
    assert_equal(writer^.finish(), expected)
    var reader = CompactReader(expected^)
    assert_equal(reader.read_i16(), Int16.MIN)
    assert_equal(reader.read_i16(), Int16.MAX)
    assert_equal(reader.read_i32(), Int32.MIN)
    assert_equal(reader.read_i32(), Int32.MAX)
    assert_equal(reader.read_i64(), Int64.MIN)
    assert_equal(reader.read_i64(), Int64.MAX)
    assert_equal(reader.read_byte(), Int8.MIN)
    reader.finish()


def test_double_bit_identity_and_utf8() raises:
    var nan_bits = UInt64(0x7FF8000000000042)
    var writer = CompactWriter()
    writer.write_double(-0.0)
    writer.write_double(bitcast[DType.float64](nan_bits))
    writer.write_string("μ\0")
    var bytes = writer^.finish()
    assert_equal(
        bytes,
        [
            UInt8(0),
            0,
            0,
            0,
            0,
            0,
            0,
            128,
            66,
            0,
            0,
            0,
            0,
            0,
            248,
            127,
            3,
            206,
            188,
            0,
        ],
    )
    var reader = CompactReader(bytes^)
    assert_equal(bitcast[DType.uint64](reader.read_double()), UInt64(1) << 63)
    assert_equal(bitcast[DType.uint64](reader.read_double()), nan_bits)
    assert_equal(reader.read_string(), "μ\0")
    reader.finish()
    with assert_raises():
        var bad = CompactReader([1, 255])
        _ = bad.read_string()


def test_collections_maps_and_boolean_context() raises:
    # Fastparquet's legacy empty-list header, also accepted by Apache Thrift.
    skip_struct([0x19, 0, 0])
    # Unknown list<bool>, map<byte,bool>, empty map, set<i16>, and UUID.
    var bytes: List[UInt8] = [
        0x19,
        0x32,
        1,
        2,
        1,
        0x1B,
        1,
        0x31,
        127,
        2,
        0x1B,
        0,
        0x1A,
        0x14,
        1,
        0x1D,
    ]
    for i in range(16):
        bytes.append(UInt8(i))
    bytes.append(0)
    skip_struct(bytes^)
    var writer = CompactWriter()
    writer.write_collection(CompactType.TRUE, 15)
    for i in range(15):
        writer.write_bool(i % 2 == 0)
    writer.write_map(0, 0, 0)
    var encoded = writer^.finish()
    assert_equal(encoded[0], UInt8(0xF1))
    assert_equal(encoded[1], UInt8(15))
    var reader = CompactReader(encoded^)
    var header = reader.read_collection()
    assert_equal(header.size, 15)
    for i in range(15):
        assert_equal(reader.read_bool(), i % 2 == 0)
    assert_equal(reader.read_map().size, 0)
    reader.finish()


def test_truncation_at_every_byte() raises:
    var full = literal_struct()
    for length in range(len(full)):
        var prefix = List[UInt8]()
        for i in range(length):
            prefix.append(full[i])
        with assert_raises():
            skip_struct(prefix^)


def test_malformed_wire_and_limits() raises:
    with assert_raises():
        skip_struct([0x10])  # STOP with an illegal delta.
    with assert_raises():
        skip_struct([0x1E, 0])  # Unknown wire tag.
    with assert_raises():
        skip_struct([0x19, 0x10, 0])  # STOP as element type.
    with assert_raises():
        skip_struct([0x19, 0x11, 0, 0])  # Illegal boolean element.
    with assert_raises():
        skip_struct([0x1B, 1, 0, 0])  # Invalid map types.
    with assert_raises():
        var reader = CompactReader([128, 128, 4])
        _ = reader.read_i16()
    with assert_raises():
        var reader = CompactReader([128, 128, 128, 128, 16])
        _ = reader.read_i32()
    with assert_raises():
        var reader = CompactReader(
            [128, 128, 128, 128, 128, 128, 128, 128, 128, 2]
        )
        _ = reader.read_i64()
    with assert_raises():
        var reader = CompactReader(
            [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 0]
        )
        _ = reader.read_i64()
    with assert_raises():
        var reader = CompactReader([255, 255, 255, 255, 15])
        _ = reader.read_binary()
    with assert_raises():
        var reader = CompactReader([5, 1])
        _ = reader.read_binary()
    with assert_raises():
        skip_struct([0x18, 3, 1, 2, 3, 0], CompactLimits(max_binary_bytes=2))
    with assert_raises():
        skip_struct(
            [0x19, 0x35, 0, 0, 0, 0], CompactLimits(max_collection_items=2)
        )
    with assert_raises():
        skip_struct([0x1C, 0, 0], CompactLimits(max_depth=1))
    with assert_raises():
        skip_struct([0x19, 0x19, 0x19, 0x15, 0, 0], CompactLimits(max_depth=2))
    with assert_raises():
        _ = CompactReader([0], CompactLimits(max_bytes=0))
    with assert_raises():
        _ = CompactReader([0], CompactLimits(max_depth=0))
    with assert_raises():
        skip_struct([0, 0])  # Trailing byte.
    with assert_raises():
        skip_struct([0x05, 0xFE, 0xFF, 0x03, 0, 0x15, 0, 0])  # 32767 + 1.


def test_negative_and_out_of_order_field_ids() raises:
    var writer = CompactWriter()
    writer.begin_struct()
    writer.write_bool_field(-32768, True)
    writer.write_bool_field(32767, False)
    writer.write_bool_field(-2, True)
    writer.end_struct()
    var bytes = writer^.finish()
    assert_equal(bytes, [UInt8(1), 255, 255, 3, 2, 254, 255, 3, 1, 3, 0])
    var reader = CompactReader(bytes^)
    reader.begin_struct()
    assert_equal(reader.next_field().field_id, -32768)
    assert_equal(reader.next_field().field_id, 32767)
    assert_equal(reader.next_field().field_id, -2)
    assert_equal(reader.next_field().kind, 0)
    reader.end_struct()
    reader.finish()


def test_writer_errors_and_unbalanced_structs() raises:
    with assert_raises():
        var writer = CompactWriter()
        writer.write_field(1, CompactType.I32)
    with assert_raises():
        var writer = CompactWriter()
        writer.begin_struct()
        writer.write_field(32768, CompactType.I32)
    with assert_raises():
        var writer = CompactWriter()
        writer.write_collection(CompactType.I32, -1)
    with assert_raises():
        var writer = CompactWriter()
        writer.begin_struct()
        _ = writer^.finish()
    with assert_raises():
        var reader = CompactReader([0])
        reader.begin_struct()
        reader.end_struct()
    var writer = CompactWriter(CompactLimits(max_bytes=1))
    with assert_raises():
        writer.write_i64(128)
    with assert_raises():
        _ = writer^.finish()


def test_nesting_limit_boundary() raises:
    # Root plus three nested structs is exactly depth four.
    skip_struct([0x1C, 0x1C, 0x1C, 0, 0, 0, 0], CompactLimits(max_depth=4))
    with assert_raises():
        skip_struct(
            [0x1C, 0x1C, 0x1C, 0x1C, 0, 0, 0, 0, 0], CompactLimits(max_depth=4)
        )
    var writer = CompactWriter(CompactLimits(max_depth=4))
    for _ in range(4):
        writer.begin_struct()
    with assert_raises():
        writer.begin_struct()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
