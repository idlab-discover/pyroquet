"""Machine-readable direct-to-NuMojo loader probe."""
from std.sys import argv
from pyroquet.numojo_io import load_uint32


def main() raises:
    var args = argv()
    var budget = 1073741824
    if len(args) > 3:
        budget = Int(args[3])
    var column = load_uint32(args[1], args[2], max_output_bytes=budget)
    print(column.size(), column.null_count())
    for i in range(column.size()):
        var value = column.value(i)
        if value:
            print(value.value())
        else:
            print("null")
