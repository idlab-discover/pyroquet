"""Hot-cache load/save timing; validation and cleanup stay outside timing."""
from std.sys import argv
from std.time import perf_counter_ns
from std.os import remove
from temp_directory import TestDirectory
from std.testing import assert_equal
from pyroquet.table_io import load_table
from pyroquet.table_write import (
    save_table,
    TableWriteOptions,
    ColumnWriteOptions,
)
from pyroquet.table import Table
from pyroquet.schema import SchemaNode


def equal(actual: Table, expected: Table) raises:
    assert_equal(actual.num_rows(), expected.num_rows())
    for c in range(actual.num_columns()):
        assert_equal(actual.column(c).kind(), expected.column(c).kind())
        for i in range(actual.num_rows()):
            if actual.column(c).kind() == SchemaNode.BOOLEAN:
                assert_equal(
                    actual.column(c).boolean().value(i),
                    expected.column(c).boolean().value(i),
                )
            else:
                ref a = actual.column(c).binary()
                ref b = expected.column(c).binary()
                assert_equal(a.is_valid(i), b.is_valid(i))
                if a.is_valid(i):
                    var av = a.value(i)
                    var bv = b.value(i)
                    assert_equal(len(av), len(bv))
                    for j in range(len(av)):
                        assert_equal(av[j], bv[j])


def main() raises:
    var args = argv()
    var source = load_table(args[2])
    var settings: List[ColumnWriteOptions] = [
        ColumnWriteOptions(page_rows=1024),
        ColumnWriteOptions(page_rows=1024),
    ]
    with TestDirectory() as directory:
        for trial in range(7):
            var path = directory + "/output.parquet"
            if args[1] == "load":
                var started = perf_counter_ns()
                var actual = load_table(args[2])
                var elapsed = perf_counter_ns() - started
                equal(actual, source)
                if trial >= 2:
                    print(elapsed)
            else:
                var started = perf_counter_ns()
                save_table(
                    path,
                    source,
                    TableWriteOptions(row_group_rows=65536),
                    settings,
                )
                var elapsed = perf_counter_ns() - started
                var actual = load_table(path)
                equal(actual, source)
                remove(path)
                if trial >= 2:
                    print(elapsed)
