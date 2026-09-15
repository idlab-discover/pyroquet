"""Page header tests using independent Apache Thrift-encoded byte fixtures."""
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from pyroquet.format import parse_page_header, PageLimits


def _v0() -> List[UInt8]:
    return [21, 0, 21, 24, 21, 24, 44, 21, 6, 21, 0, 21, 6, 21, 6, 0, 0]


def _v1() -> List[UInt8]:
    return [21, 2, 21, 24, 21, 24, 60, 0, 0]


def _v2() -> List[UInt8]:
    return [21, 4, 21, 24, 21, 24, 76, 21, 6, 21, 0, 0, 0]


def _v3() -> List[UInt8]:
    return [
        21,
        6,
        21,
        24,
        21,
        24,
        92,
        21,
        6,
        21,
        2,
        21,
        6,
        21,
        0,
        21,
        4,
        21,
        0,
        0,
        0,
    ]


def _crc() -> List[UInt8]:
    return [
        21,
        0,
        21,
        24,
        21,
        24,
        44,
        21,
        6,
        21,
        0,
        21,
        6,
        21,
        6,
        0,
        5,
        8,
        255,
        255,
        255,
        255,
        15,
        0,
    ]


def _unknown() -> List[UInt8]:
    return [
        21,
        0,
        21,
        24,
        21,
        24,
        44,
        21,
        6,
        21,
        0,
        21,
        6,
        21,
        6,
        0,
        12,
        100,
        24,
        6,
        102,
        117,
        116,
        117,
        114,
        101,
        0,
        0,
    ]


def _wrong_union() -> List[UInt8]:
    return [21, 0, 21, 24, 21, 24, 44, 21, 6, 21, 0, 21, 6, 21, 6, 0, 28, 0, 0]


def _negative() -> List[UInt8]:
    return [21, 0, 21, 1, 21, 24, 44, 21, 6, 21, 0, 21, 6, 21, 6, 0, 0]


def _v2_false() -> List[UInt8]:
    return [
        21,
        6,
        21,
        24,
        21,
        24,
        92,
        21,
        6,
        21,
        2,
        21,
        6,
        21,
        0,
        21,
        4,
        21,
        0,
        18,
        0,
        0,
    ]


def _v2_bad_levels() -> List[UInt8]:
    return [
        21,
        6,
        21,
        24,
        21,
        24,
        92,
        21,
        6,
        21,
        2,
        21,
        6,
        21,
        0,
        21,
        26,
        21,
        0,
        0,
        0,
    ]


def _bad_levels() -> List[UInt8]:
    return [21, 0, 21, 24, 21, 24, 44, 21, 6, 21, 0, 21, 0, 21, 6, 0, 0]


def test_v1_prefix_and_payload_boundary() raises:
    var bytes = _v0()
    var size = len(bytes)
    bytes.append(255)
    bytes.append(0)
    var h = parse_page_header(bytes^)
    assert_equal(h.header_size, size)
    assert_equal(h.page_type, 0)
    assert_equal(h.num_values, 3)
    assert_equal(h.encoding, 0)
    assert_equal(h.definition_level_encoding, 3)
    assert_equal(h.repetition_level_encoding, 3)
    assert_equal(h.compressed_page_size, 12)
    assert_equal(h.uncompressed_page_size, 12)


def test_v2_defaults_and_levels() raises:
    var h = parse_page_header(_v3())
    assert_equal(h.page_type, 3)
    assert_equal(h.num_rows, 3)
    assert_equal(h.num_nulls, 1)
    assert_equal(h.definition_levels_byte_length, 2)
    assert_equal(h.repetition_levels_byte_length, 0)
    assert_true(h.is_compressed)
    var plain = parse_page_header(_v2_false())
    assert_false(plain.is_compressed)
    with assert_raises():
        _ = parse_page_header(_v2_bad_levels())


def test_dictionary_index_crc_and_unknown_fields() raises:
    var dictionary = parse_page_header(_v2())
    assert_equal(dictionary.page_type, 2)
    assert_equal(dictionary.num_values, 3)
    assert_false(dictionary.has_is_sorted)
    var index = parse_page_header(_v1())
    assert_equal(index.page_type, 1)
    assert_equal(index.num_values, -1)
    var crc = parse_page_header(_crc())
    assert_true(crc.has_crc)
    assert_equal(crc.crc, Int32.MIN)
    var future = parse_page_header(_unknown())
    assert_equal(future.page_type, 0)


def test_invalid_headers_and_limits() raises:
    with assert_raises():
        _ = parse_page_header(_wrong_union())
    with assert_raises():
        _ = parse_page_header(_negative())
    with assert_raises():
        _ = parse_page_header(_bad_levels())
    with assert_raises():
        _ = parse_page_header(_v0(), PageLimits(max_header_bytes=1))
    with assert_raises():
        _ = parse_page_header(_v0(), PageLimits(max_page_bytes=11))
    with assert_raises():
        _ = parse_page_header(_v0(), PageLimits(max_header_bytes=0))
    var h = parse_page_header(_v0(), PageLimits(max_page_bytes=12))
    assert_equal(h.compressed_page_size, 12)


def test_every_truncated_header_prefix() raises:
    var bytes = _v3()
    for n in range(len(bytes)):
        var prefix = List[UInt8]()
        for i in range(n):
            prefix.append(bytes[i])
        with assert_raises():
            _ = parse_page_header(prefix^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
