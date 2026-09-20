"""GZIP numeric ownership, bounded compression/fallback and publication failures."""
from std.memory import bitcast
from std.os import listdir
from temp_directory import TestDirectory
from std.testing import TestSuite
from numojo.routines.creation import empty
from pyroquet.numojo_io import NumericColumn, load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions
from pyroquet.format import inspect_metadata, inspect_column_pages


def test_numeric_gzip_bits_and_borrowed_ownership() raises:
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
            values^, [UInt8(253), UInt8(1)], "bits", 1
        )
        for version in [1, 2]:
            var path = directory + "/v" + String(version) + ".parquet"
            save_numeric[DType.float64](
                path,
                column,
                NumericWriteOptions(
                    codec=2, page_version=version, page_rows=2, row_group_rows=5
                ),
            )
            if Int(
                column.values().unsafe_ptr()
            ) != address or column.validity()[0] != UInt8(253):
                raise Error("Saving changed borrowed numeric storage")
            var actual = load_numeric[DType.float64](path, "bits")
            if (
                actual.size() != 9
                or actual.null_count() != 1
                or actual.value(1)
            ):
                raise Error("GZIP numeric shape or validity differs")
            for i in range(9):
                if i == 1:
                    continue
                var expected = UInt64(0x8000000000000000) if i == 0 else UInt64(
                    0x7FF0000000000001
                )
                if bitcast[DType.uint64](actual.value(i).value()) != expected:
                    raise Error("GZIP floating bits differ")
            var metadata = inspect_metadata(path)
            if len(metadata.row_groups) != 2:
                raise Error("GZIP row groups differ")


def test_gzip_compression_failure_and_v2_raw_fallback() raises:
    with TestDirectory() as directory:
        var values = empty[DType.int32]([3])
        for i in range(3):
            values.unsafe_ptr()[unsafe_offset=i] = Int32(i)
        var column = NumericColumn[DType.int32](
            values^, List[UInt8](), "value", 0
        )
        var path = directory + "/result.parquet"
        for mode in range(3):
            var rejected = False
            try:
                if mode == 0:
                    # Four raw bytes fit, but the gzip member does not.
                    save_numeric[DType.int32](
                        path,
                        column,
                        NumericWriteOptions(
                            nullable=False,
                            codec=2,
                            page_rows=1,
                            max_page_bytes=8,
                        ),
                    )
                elif mode == 1:
                    # Fail after emitting compressed pages, while retaining footer.
                    save_numeric[DType.int32](
                        path,
                        column,
                        NumericWriteOptions(
                            nullable=False, codec=2, max_metadata_bytes=1
                        ),
                    )
                else:
                    save_numeric[DType.int32](
                        path,
                        column,
                        NumericWriteOptions(
                            nullable=False, codec=2, max_page_bytes=1
                        ),
                    )
            except:
                rejected = True
            if not rejected or len(listdir(directory)) != 0:
                raise Error("Failed GZIP save published or leaked staging")
        save_numeric[DType.int32](
            path,
            column,
            NumericWriteOptions(
                nullable=False,
                codec=2,
                page_version=2,
                page_rows=1,
                max_page_bytes=8,
            ),
        )
        var pages = inspect_column_pages(path, 0, 0)
        for page in pages:
            if (
                page.header.is_compressed
                or page.header.compressed_page_size
                != page.header.uncompressed_page_size
            ):
                raise Error("V2 did not preserve raw-values fallback")
        var loaded = load_numeric[DType.int32](path, "value")
        for i in range(3):
            if loaded.value(i).value() != Int32(i):
                raise Error("GZIP codec raw fallback value differs")
        var rejected = False
        try:
            save_numeric[DType.int32](
                path, column, NumericWriteOptions(codec=2)
            )
        except:
            rejected = True
        if not rejected or len(listdir(directory)) != 1:
            raise Error("Create-new publication failed to protect destination")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
