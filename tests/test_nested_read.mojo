"""Independent fixture read, precise output-budget and component projection gates.

Generate with build/oracle-uv/bin/python tests/nested_fixture_oracle.py --generate.
"""
from std.testing import assert_equal, assert_raises, TestSuite
from pyroquet.nested_io import load_nested_table, _leaf_overhead
from pyroquet.schema import SchemaNode


def test_fixture_cohorts_and_exact_budget() raises:
    var versions: List[String] = ["1.0", "2.0"]
    var encodings: List[String] = ["PLAIN", "DICTIONARY", "DELTA_BINARY_PACKED"]
    for version in versions:
        for encoding in encodings:
            var path = (
                "build/nested-fixtures/nested-"
                + version
                + "-"
                + encoding
                + ".parquet"
            )
            var table = load_nested_table(path)
            var bytes = 0
            var schema = table.schema()
            for i in range(1, len(schema)):
                var kind = schema.node(i).kind()
                if kind == SchemaNode.GROUP or kind == SchemaNode.LIST:
                    bytes += table.structure(i).retained_bytes()
                else:
                    ref leaf = table.leaf(table.leaf_index(i))
                    bytes += _leaf_overhead(kind, leaf.size(), Int.MAX)
                    if (
                        kind == SchemaNode.BINARY
                        or kind == SchemaNode.FIXED_BINARY
                    ):
                        bytes += leaf.binary().byte_size()
            var exact = load_nested_table(path, max_output_bytes=bytes)
            assert_equal(exact.num_rows(), table.num_rows())
            with assert_raises():
                _ = load_nested_table(path, max_output_bytes=bytes - 1)
            with assert_raises():
                _ = load_nested_table(path, max_output_bytes=-1)


def test_empty_projection_retains_rows_with_zero_budget() raises:
    var selection = List[List[String]]()
    var path = "build/nested-fixtures/nested-2.0-PLAIN.parquet"
    var full = load_nested_table(path)
    var projected = load_nested_table(path, selection^, max_output_bytes=0)
    assert_equal(projected.num_rows(), full.num_rows())
    assert_equal(projected.num_leaves(), 0)
    assert_equal(len(projected.schema()), 1)
    var missing: List[List[String]] = [["no-such-field"]]
    with assert_raises():
        _ = load_nested_table(path, missing^)
    var empty_path: List[List[String]] = [[]]
    with assert_raises():
        _ = load_nested_table(path, empty_path^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
