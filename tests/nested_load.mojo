"""Complete nested load timing; one warmup, owner destruction outside timer."""
from std.sys import argv
from std.time import perf_counter_ns
from pyroquet.nested_io import load_nested_table


def main() raises:
    var args = argv()
    for iteration in range(2):
        var start = perf_counter_ns()
        var table = load_nested_table(args[1], max_output_bytes=Int(args[2]))
        var elapsed = perf_counter_ns() - start
        print(
            "WARMUP" if iteration == 0 else "TIME",
            elapsed,
            table.num_rows(),
            table.num_leaves(),
        )
