"""Independent fixtures from gzip_fixture_oracle.py; checks survive ASSERT=none."""
from std.testing import TestSuite
from pyroquet.format import PageHeader
from pyroquet.format.pages import PageLimits
from pyroquet.format.flat_pages import _page_body
from pyroquet.numojo_io import load_numeric
from pyroquet.table_io import load_table


def _stream(name: String) raises -> List[UInt8]:
    var file = open("build/gzip/streams/" + name + ".bin", "r")
    var count = file.seek(0, 2)
    _ = file.seek(0)
    return file.read_bytes(Int(count))


def _header(
    kind: Int, stored: Int, decoded: Int, levels: Int = 0
) -> PageHeader:
    var h = PageHeader()
    h.page_type = kind
    h.compressed_page_size = stored
    h.uncompressed_page_size = decoded
    h.repetition_levels_byte_length = 0
    h.definition_levels_byte_length = levels
    return h


def _reject(var data: List[UInt8], h: PageHeader) raises:
    var rejected = False
    try:
        _ = _page_body(data^, h, 2)
    except:
        rejected = True
    if not rejected:
        raise Error("Malformed GZIP page unexpectedly accepted")


def test_gzip_members_and_optional_header() raises:
    for name in [
        "member",
        "optional",
        "concatenated",
        "empty",
        "empty_members",
    ]:
        var empty = name == "empty" or name == "empty_members"
        var wanted = List[UInt8]()
        if not empty:
            wanted = [42, 0, 0, 0]
        for kind in [0, 2, 3]:
            var data = _stream(name)
            var actual = _page_body(
                data.copy(), _header(kind, len(data), len(wanted)), 2
            )
            if actual != wanted:
                raise Error("GZIP body differs")
            _reject(data.copy(), _header(kind, len(data), len(wanted) + 1))
            if not empty:
                _reject(data.copy(), _header(kind, len(data), 3))
                _reject(data.copy(), _header(kind, len(data), 0))
            if kind == 3:
                var prefixed: List[UInt8] = [3, 5]
                prefixed.extend(data.copy())
                var expected: List[UInt8] = [3, 5]
                expected.extend(wanted.copy())
                var result = _page_body(
                    prefixed.copy(),
                    _header(3, len(prefixed), len(expected), 2),
                    2,
                )
                if result != expected:
                    raise Error("V2 levels or values differ")
    var h = _header(3, 6, 6, 2)
    h.is_compressed = False
    var raw: List[UInt8] = [3, 5, 42, 0, 0, 0]
    if _page_body(raw.copy(), h, 2) != raw:
        raise Error("V2 raw values differ")


def test_malformed_gzip_and_exact_bounds() raises:
    var names: List[String] = [
        "trailing",
        "trailing_zero",
        "next_member_truncated",
        "next_member_invalid",
        "zlib_wrapper",
        "raw_deflate",
        "bad_magic",
        "bad_method",
        "reserved_flags",
        "crc",
        "isize",
        "header_crc",
        "oversized",
    ]
    var member = _stream("member")
    for n in range(len(member)):
        names.append("truncated_" + String(n))
    for name in names:
        var data = _stream(name)
        for kind in [0, 2, 3]:
            _reject(data.copy(), _header(kind, len(data), 4))
    _reject(member.copy(), _header(0, len(member) + 1, 4))
    _reject(member.copy(), _header(0, len(member), -1))
    _reject(member.copy(), _header(3, len(member), 4, 5))


def test_public_numeric_and_ordered_projection() raises:
    for version in ["1", "2"]:
        for mode in ["required_plain", "mixed_plain", "mixed_dict"]:
            var path = "build/gzip/v" + version + "_" + mode + ".parquet"
            var column = load_numeric[DType.int32](path, "i32")
            if column.size() != 257:
                raise Error("Numeric GZIP row count differs")
            var nullable = mode != "required_plain"
            for i in range(257):
                var value = column.value(i)
                if nullable and i % 7 == 0:
                    if value:
                        raise Error("GZIP null became present")
                elif not value or value.value() != Int32(i % 101 - 50):
                    raise Error("GZIP numeric value differs")
            var names: List[String] = ["raw", "i32", "flag"]
            var table = load_table(path, names^)
            if table.num_rows() != 257 or table.num_columns() != 3:
                raise Error("GZIP projection shape differs")
            if (
                table.column(0).name() != "raw"
                or table.column(1).name() != "i32"
                or table.column(2).name() != "flag"
            ):
                raise Error("GZIP projection order differs")
            for i in range(257):
                var valid = not nullable or i % 7 != 0
                if (
                    table.column(0).binary().is_valid(i) != valid
                    or Bool(table.column(2).boolean().value(i)) != valid
                ):
                    raise Error("Projected validity differs")
                if valid:
                    var bytes = table.column(0).binary().value(i)
                    if len(bytes) != i % 19:
                        raise Error("Projected binary length differs")
                    for byte in bytes:
                        if byte != UInt8(i % 251):
                            raise Error("Projected binary value differs")
                    if table.column(2).boolean().value(i).value() != (
                        i % 2 == 0
                    ):
                        raise Error("Projected boolean differs")
            var empty = load_table(path, List[String]())
            if empty.num_rows() != 257 or empty.num_columns() != 0:
                raise Error("Empty projection differs")
        var fallback = load_numeric[DType.int32](
            "build/gzip/v" + version + "_fallback.parquet", "i32"
        )
        for i in range(2048):
            if fallback.value(i).value() != Int32(i):
                raise Error("Dictionary-to-PLAIN fallback differs")
        for mode in ["all_null_dict", "empty_plain"]:
            var table = load_table(
                "build/gzip/v" + version + "_" + mode + ".parquet"
            )
            var expected = 33 if mode == "all_null_dict" else 0
            if table.num_rows() != expected or table.num_columns() != 13:
                raise Error("All-null/empty table differs")


def test_public_output_and_page_budgets() raises:
    var path = "build/gzip/v1_required_plain.parquet"
    for mode in range(3):
        var rejected = False
        try:
            if mode == 0:
                _ = load_numeric[DType.int32](path, "i32", max_output_bytes=1)
            elif mode == 1:
                _ = load_table(path, max_output_bytes=1)
            else:
                _ = load_table(path, page_limits=PageLimits(max_page_bytes=1))
        except:
            rejected = True
        if not rejected:
            raise Error("GZIP budget violation accepted")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
