"""ZSTD numeric ownership, bounded compression/fallback and publication failures."""
from std.memory import bitcast
from std.os import listdir
from temp_directory import TestDirectory
from std.testing import TestSuite
from numojo.routines.creation import empty
from pyroquet.numojo_io import NumericColumn, load_numeric
from pyroquet.numojo_write import save_numeric, NumericWriteOptions
from pyroquet.format import inspect_metadata, inspect_column_pages
from pyroquet.format.pages import PageLimits


def test_numeric_zstd_bits_and_borrowed_ownership() raises:
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
                    codec=6, page_version=version, page_rows=2, row_group_rows=5
                ),
            )
            if Int(
                column.values().unsafe_ptr()
            ) != address or column.validity()[0] != UInt8(253):
                raise Error("Saving changed borrowed numeric storage")
            for budget in range(2):
                var rejected = False
                try:
                    if budget == 0:
                        _ = load_numeric[DType.float64](
                            path, "bits", max_output_bytes=1
                        )
                    else:
                        _ = load_numeric[DType.float64](
                            path,
                            "bits",
                            page_limits=PageLimits(max_page_bytes=1),
                        )
                except:
                    rejected = True
                if not rejected:
                    raise Error("ZSTD read budget violation accepted")
            var actual = load_numeric[DType.float64](path, "bits")
            if (
                actual.size() != 9
                or actual.null_count() != 1
                or actual.value(1)
            ):
                raise Error("ZSTD numeric shape or validity differs")
            for i in range(9):
                if i == 1:
                    continue
                var expected = UInt64(0x8000000000000000) if i == 0 else UInt64(
                    0x7FF0000000000001
                )
                if bitcast[DType.uint64](actual.value(i).value()) != expected:
                    raise Error("ZSTD floating bits differ")
            var metadata = inspect_metadata(path)
            if len(metadata.row_groups) != 2:
                raise Error("ZSTD row groups differ")


def test_zstd_compression_failure_and_v2_raw_fallback() raises:
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
                    # Four raw bytes fit, but the ZSTD frame does not.
                    save_numeric[DType.int32](
                        path,
                        column,
                        NumericWriteOptions(
                            nullable=False,
                            codec=6,
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
                            nullable=False, codec=6, max_metadata_bytes=1
                        ),
                    )
                else:
                    save_numeric[DType.int32](
                        path,
                        column,
                        NumericWriteOptions(
                            nullable=False, codec=6, max_page_bytes=1
                        ),
                    )
            except:
                rejected = True
            if not rejected or len(listdir(directory)) != 0:
                raise Error("Failed ZSTD save published or leaked staging")
        save_numeric[DType.int32](
            path,
            column,
            NumericWriteOptions(
                nullable=False,
                codec=6,
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
                raise Error("ZSTD codec raw fallback value differs")
        var rejected = False
        try:
            save_numeric[DType.int32](
                path, column, NumericWriteOptions(codec=6)
            )
        except:
            rejected = True
        if not rejected or len(listdir(directory)) != 1:
            raise Error("Create-new publication failed to protect destination")


def test_zstd_stream_rejection_and_offsets() raises:
    from pyroquet.compression import compress, decompress

    var source: List[UInt8] = [99, 42, 0, 0, 0]
    var encoded = compress(6, source, 1024, 1)
    if decompress(6, encoded, 4) != [UInt8(42), 0, 0, 0]:
        raise Error("ZSTD offset roundtrip differs")
    for size in [0, 3, 5]:
        var rejected = False
        try:
            _ = decompress(6, encoded, size)
        except:
            rejected = True
        if not rejected:
            raise Error("ZSTD output-size mismatch accepted")
    for n in range(len(encoded)):
        var truncated = List[UInt8]()
        for i in range(n):
            truncated.append(encoded[i])
        var rejected = False
        try:
            _ = decompress(6, truncated, 4)
        except:
            rejected = True
        if not rejected:
            raise Error("Truncated ZSTD frame accepted")
    for mode in range(3):
        var bad = encoded.copy()
        if mode == 0:
            bad[0] = 0
        elif mode == 1:
            bad.append(0)
        else:
            bad.extend(encoded.copy())
        var rejected = False
        try:
            _ = decompress(6, bad, 4)
        except:
            rejected = True
        if not rejected:
            raise Error("Invalid ZSTD bytes accepted")
    var empty = compress(6, List[UInt8](), 1024)
    if len(decompress(6, empty, 0)) != 0:
        raise Error("Empty ZSTD frame differs")
    var prefixed: List[UInt8] = [91, 92]
    prefixed.extend(encoded.copy())
    if decompress(6, prefixed, 4, 2) != [UInt8(42), 0, 0, 0]:
        raise Error("ZSTD level prefix was decoded")
    encoded.extend(encoded.copy())
    if decompress(6, encoded, 8) != [UInt8(42), 0, 0, 0, 42, 0, 0, 0]:
        raise Error("Concatenated ZSTD frames differ")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
