"""Deterministic binary16 compatibility fixtures and independent reader evidence.

NaN payloads, signed zeros and subnormals are compared as bits, never via float32.
Run --generate before test_float16.mojo and --verify afterwards.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/float16'
CODECS = {0: 'NONE', 1: 'snappy', 2: 'gzip', 6: 'zstd'}
BITS = np.array([0, 0x8000, 1, 0x3ff, 0x400, 0x3c00, 0x7bff, 0x7c00,
                 0xfc00, 0x7e01, 0x7c01, 0xfe55, 0x3555], dtype='<u2')


def array(mode):
    bits = np.arange(65536, dtype='<u2') if mode == 'exhaustive' else BITS
    if mode == 'empty':
        bits = bits[:0]
    valid = np.ones(len(bits), dtype=bool)
    if mode == 'nullable':
        valid[::3] = False
    elif mode == 'allnull':
        valid[:] = False
    bitmap = np.packbits(valid, bitorder='little')
    return pa.Array.from_buffers(pa.float16(), len(bits),
                                [pa.py_buffer(bitmap), pa.py_buffer(bits)],
                                null_count=int((~valid).sum()))


def generate():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for version in (1, 2):
        for codec, name in CODECS.items():
            for dictionary in (0, 1):
                for mode in ('required', 'nullable', 'empty', 'allnull', 'exhaustive'):
                    arr = array(mode)
                    schema = pa.schema([pa.field('half', pa.float16(), mode != 'required')])
                    path = OUT / f'in-v{version}-c{codec}-d{dictionary}-{mode}.parquet'
                    pq.write_table(pa.Table.from_arrays([arr], schema=schema), path,
                                   compression=name, data_page_version=f'{version}.0',
                                   use_dictionary=bool(dictionary), row_group_size=16387,
                                   data_page_size=1024, write_batch_size=127)
                    manifest.append(dict(file=path.name, bytes=path.stat().st_size,
                                         sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                                         encodings=[list(pq.ParquetFile(path).metadata.row_group(i).column(0).encodings)
                                                    for i in range(pq.ParquetFile(path).metadata.num_row_groups)]))
            # A required struct and nullable list both contain FLOAT16 leaves.
            half = array('nullable')
            nested = pa.table({'s': pa.StructArray.from_arrays([half], names=['half']),
                               'l': pa.ListArray.from_arrays(pa.array(np.arange(14), pa.int32()), half)})
            pq.write_table(nested, OUT / f'nested-v{version}-c{codec}.parquet',
                           compression=name, data_page_version=f'{version}.0',
                           row_group_size=5, use_dictionary=True, data_page_size=32)
    (OUT / 'fixtures.json').write_text(json.dumps(dict(
        generation='deterministic sequential binary16 bits; no RNG',
        versions={name: importlib.metadata.version(name) for name in ('pyarrow', 'numpy', 'duckdb', 'fastparquet')},
        files=manifest), indent=2))


def malformed_fixtures():
    # Independent Thrift encoder produces valid and malformed wire controls.
    from check_metadata import fields, parts, put, encode, T
    from check_pages import thrift_bytes
    for case in ('control', 'width1', 'width4', 'missing-width', 'legacy', 'physical', 'truncated', 'delta'):
        f = fields()
        schema, group, chunk, col = parts(f)
        schema[1][:] = [(1, T.I32, 7), (2, T.I32, 2), (3, T.I32, 0),
                        (4, T.STRING, b'half'), (10, T.STRUCT, [(15, T.STRUCT, [])])]
        put(col, (1, T.I32, 7))
        put(col, (3, T.LIST, (T.STRING, [b'half'])))
        body = b'\0\0\0\x80\x01\x7e'
        if case == 'width1':
            put(schema[1], (2, T.I32, 1))
        elif case == 'width4':
            put(schema[1], (2, T.I32, 4))
        elif case == 'missing-width':
            schema[1][:] = [item for item in schema[1] if item[0] != 2]
        elif case == 'legacy':
            put(schema[1], (6, T.I32, 0))
        elif case == 'physical':
            put(schema[1], (1, T.I32, 1))
            put(col, (1, T.I32, 1))
        elif case == 'truncated':
            body = body[:-1]
        header = thrift_bytes([(1, T.I32, 0), (2, T.I32, len(body)), (3, T.I32, len(body)),
                               (5, T.STRUCT, [(1, T.I32, 3), (2, T.I32, 5 if case == 'delta' else 0),
                                              (3, T.I32, 3), (4, T.I32, 3)])])
        payload = header + body
        put(col, (6, T.I64, len(payload)))
        put(col, (7, T.I64, len(payload)))
        put(group, (2, T.I64, len(payload)))
        (OUT / f'wire-{case}.parquet').write_bytes(encode(f, payload))


def bit_values(arr):
    arr = arr.combine_chunks() if isinstance(arr, pa.ChunkedArray) else arr
    bits = np.frombuffer(arr.buffers()[1], dtype='<u2', count=len(arr), offset=arr.offset * 2)
    return [int(bits[i]) if arr[i].is_valid else None for i in range(len(arr))]


def verify():
    import duckdb
    import fastparquet
    import hashlib
    results = []
    for path in sorted(OUT.glob('out-*.parquet')):
        mode = path.stem.split('-')[-1]
        expected = bit_values(array(mode))
        pf = pq.ParquetFile(path)
        schema = pf.schema.column(0)
        assert schema.physical_type == 'FIXED_LEN_BYTE_ARRAY' and schema.length == 2
        assert str(schema.logical_type) == 'Float16', schema
        assert schema.converted_type == 'NONE', schema
        assert bit_values(pq.read_table(path)['half']) == expected, path
        results.append(dict(file=path.name, reader='pyarrow', status='PASS',
                            sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        got = duckdb.sql('select * from read_parquet(?)', params=[str(path)]).to_arrow_table()
        assert got.num_rows == len(expected) and got.column_names == ['half']
        actual = got['half'].combine_chunks()
        assert got.schema.field(0).type == pa.float32(), got.schema
        float_bits = np.frombuffer(actual.buffers()[1], dtype='<u4', count=len(actual))
        nan_rows = 0
        for i, expected_bits in enumerate(expected):
            assert actual[i].is_valid == (expected_bits is not None), (path, 'duckdb validity', i)
            if expected_bits is None:
                continue
            expected_half = np.array([expected_bits], dtype='<u2').view('<f2')
            if expected_bits & 0x7c00 == 0x7c00 and expected_bits & 0x3ff:
                # Preserve the full comparison scope, but no binary16 payload
                # claim can follow from this widened oracle representation.
                assert np.isnan(actual[i].as_py()), (path, 'duckdb NaN', i)
                nan_rows += 1
            else:
                expected_float_bits = int(expected_half.astype('<f4').view('<u4')[0])
                assert int(float_bits[i]) == expected_float_bits, (path, 'duckdb value bits', i)
        results.append(dict(file=path.name, reader='duckdb', status='LIMITATION',
                            values='PASS (all rows, nulls, finite values, signed zero, infinity and NaN positions)',
                            logical_type='LIMITATION: FLOAT16 widened to FLOAT32',
                            nan_payload=f'LIMITATION: {nan_rows} widened NaNs'))
        fp = fastparquet.ParquetFile(path)
        frame = fp.to_pandas()
        assert len(frame) == len(expected) and list(frame.columns) == ['half']
        assert str(frame['half'].dtype) == 'object', frame.dtypes
        raw_mismatches = []
        for i, expected_bits in enumerate(expected):
            value = frame['half'].iloc[i]
            if expected_bits is None:
                assert value is None, (path, 'fastparquet validity', i, value)
                continue
            assert isinstance(value, bytes), (path, i, value)
            expected_bytes = expected_bits.to_bytes(2, 'little')
            # Fastparquet's fixed-byte NumPy representation trims trailing NULs.
            # Compare raw bytes AND the reversible fixed-width reconstruction;
            # report raw disagreement explicitly instead of weakening parity.
            assert value.ljust(2, b'\0') == expected_bytes, (path, 'fastparquet values', i)
            if value != expected_bytes:
                raw_mismatches.append(i)
        results.append(dict(file=path.name, reader='fastparquet', status='LIMITATION',
                            logical_type='LIMITATION: FLOAT16 exposed as raw fixed bytes',
                            reconstructed_values='PASS (all rows and nulls, fixed-width zero padding)',
                            raw_bytes='LIMITATION: trailing NUL truncation' if raw_mismatches else 'PASS',
                            raw_mismatch_count=len(raw_mismatches),
                            first_raw_mismatch=raw_mismatches[0] if raw_mismatches else None))
    for path in sorted(OUT.glob('nested-out-*.parquet')):
        source = pq.read_table(path.with_name(path.name.replace('nested-out-', 'nested-')))
        actual = pq.read_table(path)
        assert actual.schema == source.schema, (path, actual.schema, source.schema)
        for name in ('s', 'l'):
            a = actual[name].combine_chunks()
            b = source[name].combine_chunks()
            assert a.is_valid().to_pylist() == b.is_valid().to_pylist()
            if name == 's':
                assert bit_values(a.field('half')) == bit_values(b.field('half'))
            else:
                assert a.offsets.to_pylist() == b.offsets.to_pylist()
                assert bit_values(a.values) == bit_values(b.values)
        results.append(dict(file=path.name, reader='pyarrow', status='PASS', structure='PASS'))
    assert results, 'No writer outputs found'
    (OUT / 'oracle-results.json').write_text(json.dumps(results, indent=2))
    print(json.dumps({reader: {status: sum(r['reader'] == reader and r['status'] == status for r in results)
                               for status in ('PASS', 'LIMITATION')} for reader in ('pyarrow', 'duckdb', 'fastparquet')}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--generate', action='store_true')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.generate:
        generate()
        malformed_fixtures()
    if args.verify:
        verify()
