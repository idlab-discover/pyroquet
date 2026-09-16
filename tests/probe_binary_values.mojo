"""Release comparison of validated two-pass sizing and bounded one-pass growth."""
from std.sys import argv
from std.time import perf_counter_ns
from std.testing import assert_equal
from pyroquet.binary_column import BinaryColumn, BinaryBuilder
from pyroquet.format.binary_values import decode_plain_binary, _length


def one_pass(data: List[UInt8], count: Int) raises -> BinaryColumn:
    var builder = BinaryBuilder(max_bytes=len(data))
    var pos = 0
    for _ in range(count):
        var size = _length(data, pos)
        pos += 4
        if size > len(data) - pos:
            raise Error("Truncated value")
        builder.append(Span(data)[pos : pos + size])
        pos += size
    if pos != len(data):
        raise Error("Trailing value bytes")
    return builder^.freeze()


def main() raises:
    var args = argv()
    var mode = Int(args[1])
    var width = Int(args[2])
    var rows = Int(args[3])
    var iterations = Int(args[4])
    var bytes = List[UInt8]()
    for i in range(rows):
        var size = width if width >= 0 else (4096 if i % 100 == 0 else i % 7)
        for j in range(4):
            bytes.append(UInt8((UInt32(size) >> UInt32(j * 8)) & 255))
        for j in range(size):
            bytes.append(UInt8((i + j) % 256))
    var expected = one_pass(bytes, rows)
    var elapsed = Int64(0)
    for trial in range(iterations + 2):
        var start = perf_counter_ns()
        var column = decode_plain_binary(
            bytes, rows, max_bytes=len(bytes)
        ) if mode == 0 else one_pass(bytes, rows)
        var duration = Int64(perf_counter_ns() - start)
        if trial >= 2:
            elapsed += duration
        assert_equal(len(column), rows)
        for i in range(rows):
            var actual = column.value(i)
            var reference = expected.value(i)
            assert_equal(len(actual), len(reference))
            for j in range(len(actual)):
                assert_equal(actual[j], reference[j])
    print(elapsed // Int64(iterations), len(bytes))
