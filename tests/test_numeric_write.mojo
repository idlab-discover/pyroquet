"""Native writer ownership, resource limits and failure cleanup."""
from std.memory import bitcast
from std.os import listdir
from temp_directory import TestDirectory
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from numojo.routines.creation import empty
from pyroquet.numojo_io import NumericColumn, load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions
from pyroquet.format import inspect_metadata, inspect_column_pages


def test_borrowed_numeric_bits_and_validity() raises:
    with TestDirectory() as directory:
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
    with TestDirectory() as directory:
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
    with TestDirectory() as directory:
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


def test_v2_headers_levels_and_page_null_counts() raises:
    with TestDirectory() as directory:
        var values = empty[DType.int8]([9])
        for i in range(9):
            values.unsafe_ptr()[unsafe_offset=i] = Int8(i - 4)
        var column = NumericColumn[DType.int8](
            values^, [UInt8(248), UInt8(1)], "x", 3
        )
        var path = directory + "/v2.parquet"
        save_numeric[DType.int8](
            path,
            column,
            NumericWriteOptions(page_rows=3, row_group_rows=6, page_version=2),
        )
        var pages = inspect_column_pages(path, 0, 0)
        assert_equal(len(pages), 2)
        for i in range(2):
            assert_equal(pages[i].header.page_type, 3)
            assert_equal(pages[i].header.encoding, 0)
            assert_equal(pages[i].header.num_values, 3)
            assert_equal(pages[i].header.num_rows, 3)
            assert_equal(pages[i].header.num_nulls, 3 if i == 0 else 0)
            assert_equal(pages[i].header.definition_levels_byte_length, 2)
            assert_equal(pages[i].header.repetition_levels_byte_length, 0)
            assert_equal(pages[i].header.is_compressed, False)
        var file = open(path, "r")
        _ = file.seek(Int(pages[0].payload_offset))
        assert_equal(file.read_bytes(2), [UInt8(3), UInt8(0)])
        assert_equal(pages[0].header.compressed_page_size, 2)
        var loaded = load_numeric[DType.int8](path, "x")
        assert_equal(loaded.null_count(), 3)
        assert_equal(loaded.value(8).value(), Int8(4))
        var required_values = empty[DType.int8]([1])
        required_values.unsafe_ptr()[unsafe_offset=0] = -128
        var required = NumericColumn[DType.int8](
            required_values^, List[UInt8](), "x", 0
        )
        save_numeric[DType.int8](
            directory + "/required.parquet",
            required,
            NumericWriteOptions(nullable=False, page_version=2),
        )
        var required_pages = inspect_column_pages(
            directory + "/required.parquet", 0, 0
        )
        assert_equal(required_pages[0].header.definition_levels_byte_length, 0)
        assert_equal(required_pages[0].header.compressed_page_size, 4)
        with assert_raises():
            save_numeric[DType.int8](
                directory + "/invalid.parquet",
                required,
                NumericWriteOptions(page_version=3),
            )
        assert_equal(len(listdir(directory)), 2)


def test_snappy_page_sizes_and_group_totals() raises:
    with TestDirectory() as directory:
        var values = empty[DType.int64]([128])
        for i in range(128):
            values.unsafe_ptr()[unsafe_offset=i] = 42
        var column = NumericColumn[DType.int64](values^, List[UInt8](), "x", 0)
        for version in range(1, 3):
            var path = directory + "/snappy" + String(version) + ".parquet"
            save_numeric[DType.int64](
                path,
                column,
                NumericWriteOptions(
                    codec=1, page_version=version, page_rows=64
                ),
            )
            var metadata = inspect_metadata(path)
            var pages = inspect_column_pages(path, 0, 0)
            var stored = Int64(0)
            var raw = Int64(0)
            for page in pages:
                assert_true(
                    page.header.compressed_page_size
                    < page.header.uncompressed_page_size
                )
                if version == 2:
                    assert_true(page.header.is_compressed)
                    assert_true(page.header.definition_levels_byte_length > 0)
                stored += Int64(
                    page.header.header_size + page.header.compressed_page_size
                )
                raw += Int64(
                    page.header.header_size + page.header.uncompressed_page_size
                )
            assert_equal(metadata.row_groups[0].columns[0].codec, 1)
            assert_equal(
                metadata.row_groups[0].columns[0].total_compressed_size, stored
            )
            assert_equal(
                metadata.row_groups[0].columns[0].total_uncompressed_size, raw
            )
            assert_equal(metadata.row_groups[0].total_compressed_size, stored)
            assert_equal(metadata.row_groups[0].total_byte_size, raw)
            var loaded = load_numeric[DType.int64](path, "x")
            assert_equal(loaded.size(), 128)
            assert_equal(loaded.null_count(), 0)
            for i in range(128):
                assert_equal(loaded.value(i).value(), Int64(42))


def test_snappy_v2_fallback_and_v1_expansion_limit() raises:
    with TestDirectory() as directory:
        var values = empty[DType.int32]([1])
        values.unsafe_ptr()[unsafe_offset=0] = 17
        var column = NumericColumn[DType.int32](values^, List[UInt8](), "x", 0)
        # Four raw bytes fit, but their Snappy preamble/literal tag do not.
        with assert_raises():
            save_numeric[DType.int32](
                directory + "/limited.parquet",
                column,
                NumericWriteOptions(codec=1, nullable=False, max_page_bytes=4),
            )
        assert_equal(len(listdir(directory)), 0)
        with assert_raises():
            save_numeric[DType.int32](
                directory + "/invalid.parquet",
                column,
                NumericWriteOptions(codec=3),
            )
        assert_equal(len(listdir(directory)), 0)
        save_numeric[DType.int32](
            directory + "/tiny.parquet",
            column,
            NumericWriteOptions(
                codec=1, nullable=False, page_version=2, max_page_bytes=4
            ),
        )
        var tiny = inspect_column_pages(directory + "/tiny.parquet", 0, 0)
        assert_equal(tiny[0].header.is_compressed, False)
        assert_equal(tiny[0].header.compressed_page_size, 4)
        var absent = empty[DType.int32]([1])
        var null_column = NumericColumn[DType.int32](
            absent^, [UInt8(0)], "x", 1
        )
        save_numeric[DType.int32](
            directory + "/null.parquet",
            null_column,
            NumericWriteOptions(codec=1, page_version=2),
        )
        var null_pages = inspect_column_pages(directory + "/null.parquet", 0, 0)
        assert_equal(null_pages[0].header.is_compressed, False)
        assert_equal(null_pages[0].header.compressed_page_size, 2)
        assert_equal(null_pages[0].header.uncompressed_page_size, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
