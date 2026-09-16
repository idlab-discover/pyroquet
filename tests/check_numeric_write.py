"""Native numeric roundtrips and independent values, validity, bits and wire checks.

Fastparquet's page reader exposes validity separately, avoiding pandas' conflation
of float NaN and Parquet null. Its public pandas reader is checked as well.
DuckDB NaN payload preservation is not required; all other float bits are checked.
"""
from pathlib import Path
import json
import math
import struct
import subprocess
import traceback

import duckdb
import fastparquet
from fastparquet import core, converted_types, encoding
from fastparquet.cencoding import ThriftObject
from fastparquet.compression import decompress_data
import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

from check_numeric import TYPES

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/numeric-write-checks'
BINARY = OUT / 'roundtrip'
PAGE_VERSION = 1
CODEC = 0
LIMITATIONS = []
WIRE_COUNTS = {}
DUCK_TYPES = dict(zip(TYPES, ['TINYINT', 'UTINYINT', 'SMALLINT', 'USMALLINT',
                            'INTEGER', 'UINTEGER', 'BIGINT', 'UBIGINT', 'FLOAT', 'DOUBLE']))


def arrow_values(array, dtype):
    """Use Arrow buffers directly so signaling NaNs are never Python floats."""
    result = []
    for chunk in array.chunks:
        valid = chunk.is_valid().to_pylist()
        width = chunk.type.bit_width // 8
        raw = chunk.buffers()[1]
        data = bytes(raw) if raw is not None else b''
        for i, present in enumerate(valid):
            begin = (i + chunk.offset) * width
            result.append(None if not present else int.from_bytes(
                data[begin:begin + width], 'little', signed=dtype.startswith('int')))
    return result


def probe(source, target, dtype, nullable=True, page_rows=17, row_group_rows=61,
          max_page_bytes=1048576, max_metadata_bytes=67108864, max_row_groups=100000,
          name='value', page_version=None, codec=None):
    return subprocess.run([str(BINARY), dtype, str(source), str(target), name,
                           str(int(nullable)), str(page_rows), str(row_group_rows),
                           str(max_page_bytes), str(max_metadata_bytes), str(max_row_groups),
                           str(PAGE_VERSION if page_version is None else page_version),
                           str(CODEC if codec is None else codec)],
                          capture_output=True, text=True)


def expected_plain(values, dtype):
    width = max(4, getattr(pa, dtype)().bit_width // 8)
    return b''.join((v % (1 << (width * 8))).to_bytes(width, 'little')
                    for v in values if v is not None)


def fastparquet_pages(path, dtype, expected, *, emitted=False, nullable=True,
                      page_rows=17, row_group_rows=61):
    pf = fastparquet.ParquetFile(path)
    se = pf.schema.schema_element(['value'])
    assert se.repetition_type == int(nullable)
    width = getattr(pa, dtype)().bit_width
    physical = (4 if width == 32 else 5) if dtype.startswith('float') else (2 if width == 64 else 1)
    assert se.type == physical
    if not dtype.startswith('float'):
        assert str(pf.dtypes['value']).lower() == dtype
        if emitted:
            assert se.converted_type == (15 if dtype.startswith('int') else 11) + [8, 16, 32, 64].index(width)
            assert se.logicalType.INTEGER.bitWidth == width
            assert se.logicalType.INTEGER.isSigned == dtype.startswith('int')
    else:
        assert str(pf.dtypes['value']) == dtype
    raw = path.read_bytes()
    offset = pages = 0
    interior_all_null_page = False
    previous_end = 4
    for group in pf.row_groups:
        if emitted:
            assert 0 < group.num_rows <= row_group_rows
        assert len(group.columns) == 1
        metadata = group.columns[0].meta_data
        assert metadata.codec == CODEC and metadata.type == physical
        assert metadata.num_values == group.num_rows
        if emitted:
            assert set(metadata.encodings) <= {0, 3} and 0 in metadata.encodings
            assert metadata.data_page_offset == previous_end
            if CODEC == 0:
                assert metadata.total_compressed_size == metadata.total_uncompressed_size
            assert metadata.statistics.null_count == expected[offset:offset + group.num_rows].count(None)
        stream = encoding.NumpyIO(raw)
        stream.seek(metadata.data_page_offset)
        group_start = stream.tell()
        group_rows = 0
        uncompressed_size = 0
        while group_rows < group.num_rows:
            header_start = stream.tell()
            header = ThriftObject.from_buffer(stream, 'PageHeader')
            source_version = PAGE_VERSION if CODEC else 1
            assert header.type == (3 if (PAGE_VERSION if emitted else source_version) == 2 else 0), (path, header.type, PAGE_VERSION)
            dh = header.data_page_header_v2 if header.type == 3 else header.data_page_header
            assert dh.encoding == 0
            if header.type == 0:
                assert dh.definition_level_encoding == 3
            if emitted:
                assert 0 < dh.num_values <= page_rows
            body_start = stream.tell()
            body = raw[body_start:body_start + header.compressed_page_size]
            assert len(body) == header.compressed_page_size
            uncompressed_size += body_start - header_start + header.uncompressed_page_size
            plain_body = body
            if emitted:
                key = ('v2-compressed-values' if dh.is_compressed else 'v2-raw-values') if header.type == 3 else ('v1-snappy' if CODEC else 'v1-raw')
                WIRE_COUNTS[key] = WIRE_COUNTS.get(key, 0) + 1
            if header.type == 3:
                assert dh.num_rows == dh.num_values
                assert dh.num_nulls == expected[offset:offset + dh.num_values].count(None)
                assert dh.repetition_levels_byte_length == 0
                if CODEC == 0:
                    assert dh.is_compressed is False
                if dh.is_compressed and CODEC:
                    levels = dh.definition_levels_byte_length
                    plain_body = body[:levels] + bytes(decompress_data(
                        np.frombuffer(body[levels:], dtype="uint8"),
                        header.uncompressed_page_size - levels, metadata.codec))
                levels_size = dh.definition_levels_byte_length
                assert 0 <= levels_size <= len(body)
                assert (levels_size > 0) == nullable
                if nullable:
                    defs = np.empty(dh.num_values, dtype='uint8')
                    core.encoding.read_rle_bit_packed_hybrid(
                        encoding.NumpyIO(body[:levels_size]), 1, levels_size,
                        encoding.NumpyIO(defs), itemsize=1)
                    valid = (defs == 1).tolist()
                else:
                    valid = [True] * dh.num_values
                # Run the real Fastparquet V2 decoder on a page-sized target.
                # This avoids its public reader's whole-row-group mask bug;
                # public reading is still attempted and reported separately.
                if dtype.startswith('int') or dtype.startswith('uint'):
                    assign = pd.array(np.zeros(dh.num_values, dtype=dtype),
                                      dtype=dtype.replace('int', 'Int').replace('uInt', 'UInt'))
                else:
                    assign = np.zeros(dh.num_values, dtype=dtype)
                # Bound the input too: Fastparquet NumpyIO.read(0) otherwise
                # consumes subsequent pages when this page has no values.
                page_stream = encoding.NumpyIO(body)
                core.read_data_page_v2(page_stream, pf.schema, se, dh, metadata,
                                       None, assign, 0, False, 0, header)
                assert page_stream.tell() == len(body)
                stream.seek(body_start + len(body))
                interior_all_null_page |= (dh.num_nulls == dh.num_values
                                           and group_rows + dh.num_values < group.num_rows)
                if hasattr(assign, '_mask'):
                    assert (~assign._mask).tolist() == valid
                    vals = assign._data[np.array(valid)]
                else:
                    vals = assign[np.array(valid)]
            else:
                if CODEC:
                    plain_body = bytes(decompress_data(
                        np.frombuffer(body, dtype="uint8"), header.uncompressed_page_size, metadata.codec))
                defs, reps, vals = core.read_data_page(stream, pf.schema, header, metadata)
                assert reps is None
                valid = [True] * dh.num_values if defs is None else [int(v) == 1 for v in defs]
            wanted = expected[offset:offset + dh.num_values]
            assert valid == [v is not None for v in wanted], (path, offset)
            vals = converted_types.convert(vals, se)
            if dtype.startswith('float'):
                got = vals.view('uint' + str(width)).tolist()
            else:
                got = vals.tolist()
            assert got == [v for v in wanted if v is not None], (path, offset, got, wanted)
            if emitted:
                levels_size = (dh.definition_levels_byte_length if header.type == 3 else
                               4 + int.from_bytes(plain_body[:4], 'little') if nullable else 0)
                assert plain_body[levels_size:] == expected_plain(wanted, dtype), (path, offset, 'PLAIN bytes/padding')
                assert header.uncompressed_page_size == len(plain_body)
            group_rows += dh.num_values
            offset += dh.num_values
            pages += 1
        assert group_rows == group.num_rows
        if emitted:
            assert stream.tell() - group_start == metadata.total_compressed_size
            assert group.total_byte_size == metadata.total_uncompressed_size == uncompressed_size
        previous_end = stream.tell()
    assert offset == len(expected)
    if emitted:
        footer_size = int.from_bytes(raw[-8:-4], 'little')
        assert previous_end == len(raw) - footer_size - 8
        assert pf.fmd.num_rows == len(expected)
    # Public Fastparquet conversion checks values/order/type. Page-level checks
    # above certify null positions and float bits which pandas cannot represent.
    try:
        series = pf.to_pandas()['value']
        assert str(series.dtype).lower() == dtype
        assert len(series) == len(expected)
        for actual, wanted in zip(series, expected):
            if wanted is None:
                assert pd.isna(actual)
            elif dtype.startswith('float'):
                fmt = '<f' if width == 32 else '<d'
                wanted_float = struct.unpack(fmt, wanted.to_bytes(width // 8, 'little'))[0]
                if math.isnan(wanted_float):
                    assert math.isnan(actual)
                else:
                    assert struct.pack(fmt, actual) == wanted.to_bytes(width // 8, 'little')
            else:
                assert int(actual) == wanted
    except (IndexError, TypeError) as error:
        # Both failures are independently reproduced with PyArrow V2 files;
        # neither counts as a successful public-reader comparison.
        mask_bug = (isinstance(error, IndexError)
                    and 'boolean index did not match indexed array' in str(error)
                    and not dtype.startswith('float') and any(v is None for v in expected)
                    and any(g.num_rows > page_rows for g in pf.row_groups))
        cursor_bug = (isinstance(error, TypeError) and str(error) == 'an integer is required'
                      and dtype.startswith('float') and interior_all_null_page
                      and '_read_page' in traceback.format_exc())
        if not (emitted and PAGE_VERSION == 2 and nullable and (mask_bug or cursor_bug)):
            raise
        LIMITATIONS.append({'file': str(path), 'oracle': 'Fastparquet public to_pandas',
                            'version': fastparquet.__version__,
                            'error': type(error).__name__ + ': ' + str(error),
                            'traceback': traceback.format_exc(),
                            'status': 'unsupported; page-level comparison passed'})
    return pages


def compare(path, dtype, expected, db, **wire_options):
    table = pq.read_table(path)
    assert table.schema.field('value').type == getattr(pa, dtype)()
    assert table.schema.field('value').nullable == wire_options['nullable']
    assert arrow_values(table['value'], dtype) == expected, path
    rows = db.execute('SELECT value FROM read_parquet(?)', [str(path)]).fetchall()
    assert str(db.description[0][1]) == DUCK_TYPES[dtype]
    assert len(rows) == len(expected)
    width = getattr(pa, dtype)().bit_width
    for (actual,), wanted in zip(rows, expected):
        if wanted is None:
            assert actual is None
        elif dtype.startswith('float'):
            fmt = '<f' if width == 32 else '<d'
            wanted_float = struct.unpack(fmt, wanted.to_bytes(width // 8, 'little'))[0]
            if math.isnan(wanted_float):
                assert actual is not None and math.isnan(actual)
            else:
                assert struct.pack(fmt, actual) == wanted.to_bytes(width // 8, 'little')
        else:
            assert actual == wanted
    return fastparquet_pages(path, dtype, expected, **wire_options)


def run_version():
    OUT.mkdir(parents=True, exist_ok=True)
    files = pages = rows = rejected = 0
    db = duckdb.connect()
    for dtype in TYPES:
        typ = getattr(pa, dtype)()
        width = typ.bit_width
        if dtype.startswith('float'):
            special = [0., -0., 1.5, -2.25, float('inf'), -float('inf'), float('nan'),
                       float(np.finfo(dtype).max),
                       struct.unpack('<f' if width == 32 else '<d', (1).to_bytes(width // 8, 'little'))[0]]
        else:
            signed = dtype.startswith('int')
            special = [0, 1, -(2 ** (width - 1)) if signed else 2 ** (width - 1),
                       2 ** (width - int(signed)) - 1]
            if signed:
                special.append(-1)
        patterns = {'required': (special * 37, False),
                    'nullable-valid': (special * 37, True),
                    'mixed': ([None if i % 7 == 0 else special[i % len(special)] for i in range(277)], True),
                    'runs': ([None] * 19 + special * 4 + [None] * 63 + special, True),
                    'all-null': ([None] * 131, True),
                    'empty': ([], True), 'empty-required': ([], False)}
        for label, (values, nullable) in patterns.items():
            source = OUT / f'{dtype}-{label}-source.parquet'
            target = OUT / f'{dtype}-{label}-native.parquet'
            schema = pa.schema([pa.field('value', typ, nullable=nullable)])
            table = pa.Table.from_arrays([pa.array(values, type=typ)], schema=schema)
            pq.write_table(table, source, compression='SNAPPY' if CODEC else 'NONE', use_dictionary=False,
                           data_page_version=f'{PAGE_VERSION if CODEC else 1}.0', row_group_size=101, write_statistics=False)
            expected = arrow_values(table['value'], dtype)
            compare(source, dtype, expected, db, nullable=nullable)
            target.unlink(missing_ok=True)
            result = probe(source, target, dtype, nullable=nullable)
            assert result.returncode == 0, (target, result.stdout, result.stderr)
            assert result.stdout.strip() == f'{len(values)} {values.count(None)}'
            pages += compare(target, dtype, expected, db, emitted=True, nullable=nullable)
            files += 1
            rows += len(values)
            before = target.read_bytes()
            assert probe(source, target, dtype, nullable=nullable).returncode != 0
            assert target.read_bytes() == before
            rejected += 1
        if dtype.startswith('float'):
            bits = ([0x80000000, 0x7f800001, 0xffc12345] if width == 32 else
                    [0x8000000000000000, 0x7ff0000000000001, 0xfff8123456789abc])
            source = OUT / f'{dtype}-payload-source.parquet'
            target = OUT / f'{dtype}-payload-native.parquet'
            array = pa.Array.from_buffers(typ, len(bits), [None, pa.py_buffer(
                b''.join(v.to_bytes(width // 8, 'little') for v in bits))])
            table = pa.Table.from_arrays([array], schema=pa.schema([pa.field('value', typ, nullable=False)]))
            pq.write_table(table, source, compression='SNAPPY' if CODEC else 'NONE',
                           data_page_version=f'{PAGE_VERSION if CODEC else 1}.0',
                           use_dictionary=False, write_statistics=False)
            compare(source, dtype, bits, db, nullable=False)
            target.unlink(missing_ok=True)
            result = probe(source, target, dtype, nullable=False, page_rows=1)
            assert result.returncode == 0, (result.stdout, result.stderr)
            pages += compare(target, dtype, bits, db, emitted=True, nullable=False, page_rows=1)
            files += 1
            rows += 3
    source = OUT / 'int32-mixed-source.parquet'
    for label, options in [
        ('null-required', {'nullable': False}),
        ('codec-negative', {'codec': -1}), ('codec-unsupported', {'codec': 2}),
        ('version-zero', {'page_version': 0}), ('version-three', {'page_version': 3}),
        ('version-negative', {'page_version': -1}),
        ('zero-page', {'page_rows': 0}), ('negative-page', {'page_rows': -1}),
        ('zero-group', {'row_group_rows': 0}), ('negative-group', {'row_group_rows': -1}),
        ('zero-page-bytes', {'max_page_bytes': 0}), ('small-page-bytes', {'max_page_bytes': 1}),
        ('zero-metadata', {'max_metadata_bytes': 0}), ('small-metadata', {'max_metadata_bytes': 1}),
        ('zero-groups', {'max_row_groups': 0}), ('too-many-groups', {'max_row_groups': 1}),
    ]:
        target = OUT / f'rejected-{label}.parquet'
        target.unlink(missing_ok=True)
        before = set(OUT.iterdir())
        result = probe(source, target, 'int32', **options)
        assert result.returncode != 0, label
        assert not target.exists(), label
        assert set(OUT.iterdir()) == before, (label, 'temporary file leak')
        rejected += 1
    # Exercise exact page/footer limits and deliberate output nullability changes.
    raw_page_bound = 80 if PAGE_VERSION == 1 else 76
    raw_small_group_bound = 22 if PAGE_VERSION == 1 else 18
    # V1 compresses the entire body even when Snappy expands it. Preserve the
    # exact raw-bound tests for NONE; allow the encoder's worst case for Snappy.
    page_bound = 32 + raw_page_bound + raw_page_bound // 6 if CODEC and PAGE_VERSION == 1 else raw_page_bound
    small_group_bound = 32 + raw_small_group_bound + raw_small_group_bound // 6 if CODEC and PAGE_VERSION == 1 else raw_small_group_bound
    for label, source_label, options in [
        ('snappy-page-bound' if CODEC and PAGE_VERSION == 1 else 'exact-page-bound', 'mixed', {'max_page_bytes': page_bound}),
        ('group-smaller-than-page', 'mixed', {'row_group_rows': 3, 'max_page_bytes': small_group_bound}),
        ('required-to-optional', 'required', {'nullable': True}),
        ('optional-to-required', 'nullable-valid', {'nullable': False}),
        ('zero-groups-empty', 'empty', {'max_row_groups': 0}),
    ]:
        source = OUT / f'int32-{source_label}-source.parquet'
        target = OUT / f'{label}-native.parquet'
        target.unlink(missing_ok=True)
        expected = arrow_values(pq.read_table(source)['value'], 'int32')
        outcome = probe(source, target, 'int32', **options)
        assert outcome.returncode == 0, (label, outcome.stdout, outcome.stderr)
        pages += compare(target, 'int32', expected, db, emitted=True,
                         nullable=options.get('nullable', True),
                         row_group_rows=options.get('row_group_rows', 61))
        files += 1
        rows += len(expected)
    source = OUT / 'int32-mixed-source.parquet'
    reference = OUT / 'int32-mixed-native.parquet'
    metadata_size = int.from_bytes(reference.read_bytes()[-8:-4], 'little')
    for budget, success in [(metadata_size, True), (metadata_size - 1, False)]:
        target = OUT / f'footer-bound-{budget}.parquet'
        target.unlink(missing_ok=True)
        before = set(OUT.iterdir())
        outcome = probe(source, target, 'int32', max_metadata_bytes=budget)
        assert (outcome.returncode == 0) == success, (budget, outcome.stdout, outcome.stderr)
        if success:
            assert target.read_bytes() == reference.read_bytes()
            pages += compare(target, 'int32', arrow_values(pq.read_table(source)['value'], 'int32'),
                             db, emitted=True, nullable=True)
            files += 1
            rows += 277
        else:
            assert not target.exists() and set(OUT.iterdir()) == before
            rejected += 1
    target = OUT / 'one-byte-below-page-bound.parquet'
    target.unlink(missing_ok=True)
    before = set(OUT.iterdir())
    assert probe(source, target, 'int32', max_page_bytes=79 if PAGE_VERSION == 1 else 75).returncode != 0
    assert not target.exists() and set(OUT.iterdir()) == before
    rejected += 1
    db.close()
    if CODEC and PAGE_VERSION == 2:
        assert WIRE_COUNTS.get('v2-compressed-values', 0) > 0
        assert WIRE_COUNTS.get('v2-raw-values', 0) > 0
    result = {'native_files': files, 'values_and_nulls': rows, 'native_pages': pages,
              'rejections': rejected, 'oracles': ['PyArrow', 'DuckDB', 'Fastparquet'],
              'float_bits': 'Native, Arrow buffers and Fastparquet page buffers preserve all tested bits; DuckDB and pandas check NaN semantics and all non-NaN bits.',
              'page_version': PAGE_VERSION, 'codec': 'SNAPPY' if CODEC else 'NONE',
              'wire_pages': WIRE_COUNTS.copy(),
              'unsupported_oracle_comparisons': len(LIMITATIONS),
              'oracle_limitations': LIMITATIONS.copy()}
    (OUT / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'oracle_limitations'}, indent=2))


def main():
    global OUT, PAGE_VERSION, CODEC
    base = OUT
    base.mkdir(parents=True, exist_ok=True)
    subprocess.run(['pixi', 'run', 'mojo', 'build', '-O3', '-D', 'ASSERT=all',
                    '-I', 'src', '-I', '../NuMojo', 'tests/roundtrip_numeric.mojo',
                    '-o', str(BINARY)], cwd=ROOT, check=True)
    for codec in (0, 1):
        CODEC = codec
        for version in (1, 2):
            PAGE_VERSION = version
            OUT = base / (f'snappy-v{version}' if codec else f'v{version}')
            LIMITATIONS.clear()
            WIRE_COUNTS.clear()
            run_version()


if __name__ == '__main__':
    main()
