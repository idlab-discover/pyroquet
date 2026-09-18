"""Bounded multilevel framing, malformed controls, and V1 continuation."""
from std.testing import assert_equal, assert_raises, TestSuite
from pyroquet.format.nested_levels import _NestedLevels
from pyroquet.format.pages import PageHeader


def _header(
    count: Int, rows: Int, nulls: Int, reps: Int, defs: Int
) -> PageHeader:
    var h = PageHeader()
    h.page_type = 3
    h.num_values = count
    h.num_rows = rows
    h.num_nulls = nulls
    h.repetition_levels_byte_length = reps
    h.definition_levels_byte_length = defs
    return h


def _consume(
    data: List[UInt8], h: PageHeader, rep: Int = 1, definition: Int = 3
) raises:
    var decoder = _NestedLevels(data, h, rep, definition)
    for _ in range(h.num_values):
        _ = decoder.next(data)
    decoder.finish()


def test_multilevel_list_patterns_and_v2_counts() raises:
    # RLE pairs: reps 0,0,0,1,0; defs 0(null),1(empty),2(null element),3(value),3.
    var data: List[UInt8] = [6, 0, 2, 1, 2, 0, 2, 0, 2, 1, 2, 2, 4, 3]
    var h = _header(5, 4, 3, 6, 8)
    var decoder = _NestedLevels(data, h, 1, 3)
    var definitions: List[Int] = [0, 1, 2, 3, 3]
    for i in range(5):
        var pair = decoder.next(data)
        assert_equal(pair[0], 1 if i == 3 else 0)
        assert_equal(pair[1], definitions[i])
    decoder.finish()
    assert_equal(decoder.start, 14)
    h.num_rows = 5
    with assert_raises():
        _consume(data, h)
    h.num_rows = 4
    h.num_nulls = 2
    with assert_raises():
        _consume(data, h)


def test_v1_accepts_continuation_but_v2_rejects() raises:
    var data: List[UInt8] = [2, 1, 2, 3]
    with assert_raises():
        _consume(data, _header(1, 0, 0, 2, 2))
    data = [2, 0, 0, 0, 2, 1, 2, 0, 0, 0, 2, 3]
    var h = PageHeader()
    h.page_type = 0
    h.num_values = 1
    h.repetition_level_encoding = 3
    h.definition_level_encoding = 3
    _consume(data, h)
    # The row reconstruction layer (not this page parser) must ensure a
    # preceding element exists and that there is no offset index.


def test_invalid_ranges_truncated_streams_and_trailing_levels() raises:
    var data: List[UInt8] = [2, 0, 2, 2]
    _consume(data, _header(1, 1, 1, 2, 2))
    # Maximum definition 2 uses two bits, but encoded 3 is invalid.
    data[3] = 3
    with assert_raises():
        _consume(data, _header(1, 1, 0, 2, 2), 1, 2)
    data[1] = 2
    with assert_raises():
        _consume(data, _header(1, 1, 0, 2, 2))
    for length in range(4):
        var truncated = List[UInt8](length=length, fill=0)
        with assert_raises():
            _consume(truncated, _header(1, 1, 0, 2, 2))
    data = [2, 0, 0, 2, 3]
    with assert_raises():
        _consume(data, _header(1, 1, 0, 3, 2))
    var empty = List[UInt8]()
    _consume(empty, _header(0, 0, 0, 0, 0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
