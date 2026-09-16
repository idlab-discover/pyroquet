"""Packed materialization boundaries, initialized tails, and bounded writes."""
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite
from pyroquet.format.hybrid import _HybridDecoder
from pyroquet.numojo_io import _gather_dictionary


def _packed(
    count: Int, width: Int = 2, cardinality: Int = 2, invalid: Int = -1
) -> List[UInt8]:
    # Encode only the final group's legal padding, with invalid dictionary IDs
    # there deliberately. The stream decoder must accept these unused bits.
    var groups = (count + 7) // 8
    var data: List[UInt8] = [UInt8(groups * 2 + 1)]
    data.extend(List[UInt8](length=groups * width, fill=0))
    var mask = UInt32(0xFFFFFFFF)
    if width < 32:
        mask = (UInt32(1) << UInt32(width)) - 1
    for i in range(groups * 8):
        var value = UInt32(i % cardinality)
        if i >= count or i == invalid:
            value = mask
        for bit in range(width):
            var position = i * width + bit
            data[1 + position // 8] |= UInt8(
                (value >> UInt32(bit)) & 1
            ) << UInt8(position % 8)
    return data^


def _assert_bits[
    dtype: DType
](actual: Scalar[dtype], expected: Scalar[dtype]) raises:
    comptime if dtype == DType.float32:
        assert_equal(
            bitcast[DType.uint32](actual), bitcast[DType.uint32](expected)
        )
    elif dtype == DType.float64:
        assert_equal(
            bitcast[DType.uint64](actual), bitcast[DType.uint64](expected)
        )
    else:
        assert_equal(actual, expected)


def _check[
    dtype: DType
](
    data: List[UInt8],
    width: Int,
    expected_ids: List[UInt32],
    dictionary: List[Scalar[dtype]],
    reject: Bool = False,
    decoder_count: Int = -1,
) raises:
    var count = len(expected_ids)
    var output = List[Scalar[dtype]](length=count + 4, fill=Scalar[dtype](19))
    var decoder = _HybridDecoder(
        0, len(data), width, count if decoder_count < 0 else decoder_count
    )
    if reject:
        with assert_raises():
            _gather_dictionary[dtype](
                data, decoder, dictionary, Span(output)[2 : count + 2]
            )
    else:
        _gather_dictionary[dtype](
            data, decoder, dictionary, Span(output)[2 : count + 2]
        )
        for i in range(count):
            _assert_bits[dtype](output[i + 2], dictionary[Int(expected_ids[i])])
    # Guards apply to both successful and failed materialization. Partial writes
    # inside this private destination on failure are allowed; publication is a
    # separate caller invariant tested by the full column/table readers.
    for i in range(2):
        _assert_bits[dtype](output[i], Scalar[dtype](19))
        _assert_bits[dtype](output[count + 2 + i], Scalar[dtype](19))


def _ids(count: Int, cardinality: Int = 2) -> List[UInt32]:
    var result = List[UInt32]()
    for i in range(count):
        result.append(UInt32(i % cardinality))
    return result^


def _typed_cases[dtype: DType]() raises:
    var dictionary: List[Scalar[dtype]] = [Scalar[dtype](3), Scalar[dtype](7)]
    # Every count below one scratch batch, both sides of the batch boundary,
    # and a second full batch followed by a partial tail.
    for count in range(1, 66):
        var expected = _ids(count)
        _check[dtype](_packed(count), 2, expected, dictionary)
        _check[dtype](
            _packed(count, invalid=count - 1), 2, expected, dictionary, True
        )
    for count in range(121, 130):
        var expected = _ids(count)
        _check[dtype](_packed(count), 2, expected, dictionary)
        _check[dtype](
            _packed(count, invalid=count - 1), 2, expected, dictionary, True
        )
    var boundaries: List[Int] = [0, 7, 8, 31, 32, 63, 64]
    var expected = _ids(65)
    for position in boundaries:
        _check[dtype](
            _packed(65, invalid=position), 2, expected, dictionary, True
        )
    _check[dtype](_packed(65, 32, 2, 64), 32, expected, dictionary, True)

    var singleton: List[Scalar[dtype]] = [Scalar[dtype](11)]
    expected = _ids(65, 1)
    _check[dtype](_packed(65, 2, 1), 2, expected, singleton)
    _check[dtype](_packed(65, 0, 1), 0, expected, singleton)
    var empty_dictionary = List[Scalar[dtype]]()
    _check[dtype](_packed(65, 0, 1), 0, expected, empty_dictionary, True)
    var empty_data = List[UInt8]()
    var empty_ids = List[UInt32]()
    _check[dtype](empty_data, 0, empty_ids, empty_dictionary)
    var trailing: List[UInt8] = [2]
    _check[dtype](trailing, 0, empty_ids, empty_dictionary, True)

    # A long repeated run, a full packed batch, a repeated run, then a partial
    # packed tail. Reuse of scratch must not expose stale entries from any run.
    var mixed: List[UInt8] = [0x82, 2, 1]
    expected = List[UInt32](length=129, fill=1)
    var packed = _packed(64)
    mixed.extend(Span(packed))
    expected.extend(_ids(64))
    mixed.append(6)
    mixed.append(0)
    expected.extend(List[UInt32](length=3, fill=0))
    packed = _packed(3)
    mixed.extend(Span(packed))
    expected.extend(_ids(3))
    _check[dtype](mixed, 2, expected, dictionary)
    # An invalid repeated ID after valid packed output must still be rejected.
    mixed = _packed(64)
    mixed.append(2)
    mixed.append(3)
    expected = _ids(65)
    _check[dtype](mixed, 2, expected, dictionary, True)

    # Structural errors after a completely materialized batch, including a
    # finish-time trailing-byte error after all requested values were written.
    mixed = _packed(64)
    mixed.append(3)  # A packed group without its payload.
    _check[dtype](mixed, 2, expected, dictionary, True)
    mixed = _packed(64)
    mixed.append(0x80)  # Truncated next run header.
    _check[dtype](mixed, 2, expected, dictionary, True)
    mixed = _packed(64)
    mixed.append(0)
    expected = _ids(64)
    _check[dtype](mixed, 2, expected, dictionary, True)
    mixed = _packed(65)
    expected = _ids(64)
    _check[dtype](mixed, 2, expected, dictionary, True, 65)
    expected = _ids(66)
    _check[dtype](mixed, 2, expected, dictionary, True, 65)


def test_packed_bounds_and_failures_all_numeric_types() raises:
    comptime types = (
        DType.int8,
        DType.uint8,
        DType.int16,
        DType.uint16,
        DType.int32,
        DType.uint32,
        DType.int64,
        DType.uint64,
        DType.float32,
        DType.float64,
    )
    comptime for i in range(len(types)):
        _typed_cases[types[i]]()


def test_float_special_bits_across_batches_and_transitions() raises:
    var bits32: List[UInt32] = [
        0,
        0x80000000,
        0x7F800000,
        0xFF800000,
        0x7FC12345,
        0xFFC54321,
        0x7F812345,
        1,
    ]
    var bits64: List[UInt64] = [
        0,
        0x8000000000000000,
        0x7FF0000000000000,
        0xFFF0000000000000,
        0x7FF8123456789ABC,
        0xFFF854321ABCDEF0,
        0x7FF0123456789ABC,
        1,
    ]
    var dictionary32 = List[Float32]()
    var dictionary64 = List[Float64]()
    for i in range(8):
        dictionary32.append(bitcast[DType.float32](bits32[i]))
        dictionary64.append(bitcast[DType.float64](bits64[i]))
    var expected = _ids(65, 8)
    var data = _packed(65, 4, 8)
    _check[DType.float32](data, 4, expected, dictionary32)
    _check[DType.float64](data, 4, expected, dictionary64)
    # Repeated SIMD stores must preserve the same bits as packed scalar stores.
    for index in range(8):
        data = [0x82, 2, UInt8(index)]
        data.extend(_packed(65, 4, 8))
        expected = List[UInt32](length=129, fill=UInt32(index))
        expected.extend(_ids(65, 8))
        _check[DType.float32](data, 4, expected, dictionary32)
        _check[DType.float64](data, 4, expected, dictionary64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
