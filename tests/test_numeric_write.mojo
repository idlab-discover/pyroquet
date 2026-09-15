"""Native writer ownership, resource limits and failure cleanup."""
from std.memory import bitcast
from std.os import listdir
from std.tempfile import TemporaryDirectory
from std.testing import assert_equal, assert_raises, TestSuite
from numojo.routines.creation import empty
from pyroquet.numojo_io import NumericColumn, load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions
from pyroquet.format import inspect_metadata, inspect_column_pages


def test_borrowed_numeric_bits_and_validity() raises:
    with TemporaryDirectory() as directory:
        var values = empty[DType.float64]([9])
        var address = Int(values.unsafe_ptr())
        for i in range(9):
            values.unsafe_ptr()[unsafe_offset=i] = bitcast[DType.float64](
                UInt64(0x7FF0000000000001)
            )
        values.unsafe_ptr()[unsafe_offset=0] = bitcast[DType.float64](
            UInt64(0x8000000000000000)
        )
        var column = NumericColumn[DType.float64](
            values^, [UInt8(253), UInt8(1)], "a.b", 1
        )
        var target = directory + "/result.parquet"
        save_numeric[DType.float64](
            target, column, NumericWriteOptions(page_rows=2, row_group_rows=5)
        )
        assert_equal(Int(column.values().unsafe_ptr()), address)
        assert_equal(column.validity()[0], UInt8(253))
        var result = load_numeric[DType.float64](target, "a.b")
        assert_equal(result.null_count(), 1)
        assert_equal(result.size(), 9)
        assert_equal(
            bitcast[DType.uint64](result.value(0).value()),
            UInt64(0x8000000000000000),
        )
        assert_equal(
            bitcast[DType.uint64](result.value(8).value()),
            UInt64(0x7FF0000000000001),
        )
        var metadata = inspect_metadata(target)
        assert_equal(len(metadata.row_groups), 2)
        assert_equal(metadata.schema[1].repetition, 1)
        var pages = inspect_column_pages(target, 0, 0)
        assert_equal(len(pages), 3)


def test_writer_failure_cleans_staging() raises:
    with TemporaryDirectory() as directory:
        var values = empty[DType.int16]([3])
        for i in range(3):
            values.unsafe_ptr()[unsafe_offset=i] = Int16(i)
        var column = NumericColumn[DType.int16](values^, List[UInt8](), "x", 0)
        var target = directory + "/result.parquet"
        # This fails after page emission, while constructing the footer.
        with assert_raises():
            save_numeric[DType.int16](
                target, column, NumericWriteOptions(max_metadata_bytes=1)
            )
        assert_equal(len(listdir(directory)), 0)
        with assert_raises():
            save_numeric[DType.int16](
                target, column, NumericWriteOptions(max_page_bytes=1)
            )
        assert_equal(len(listdir(directory)), 0)
        with assert_raises():
            save_numeric[DType.int16](
                target,
                column,
                NumericWriteOptions(row_group_rows=1, max_row_groups=2),
            )
        assert_equal(len(listdir(directory)), 0)
        save_numeric[DType.int16](
            target, column, NumericWriteOptions(nullable=False)
        )
        var file = open(target, "r")
        var before = file.read_bytes()
        file.close()
        with assert_raises():
            save_numeric[DType.int16](target, column)
        file = open(target, "r")
        assert_equal(file.read_bytes(), before)
        assert_equal(len(listdir(directory)), 1)


def test_required_rejects_nulls_and_empty_preserves_policy() raises:
    with TemporaryDirectory() as directory:
        var values = empty[DType.uint8]([1])
        values.unsafe_ptr()[unsafe_offset=0] = 0
        var column = NumericColumn[DType.uint8](values^, [UInt8(0)], "x", 1)
        with assert_raises():
            save_numeric[DType.uint8](
                directory + "/null.parquet",
                column,
                NumericWriteOptions(nullable=False),
            )
        assert_equal(len(listdir(directory)), 0)
        var no_values = empty[DType.uint8]([0])
        var empty_column = NumericColumn[DType.uint8](
            no_values^, List[UInt8](), "x", 0
        )
        save_numeric[DType.uint8](
            directory + "/empty.parquet",
            empty_column,
            NumericWriteOptions(nullable=False, max_row_groups=0),
        )
        var metadata = inspect_metadata(directory + "/empty.parquet")
        assert_equal(metadata.num_rows, Int64(0))
        assert_equal(len(metadata.row_groups), 0)
        assert_equal(metadata.schema[1].repetition, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
