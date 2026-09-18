"""Independent GZIP fixtures and three-reader parity; artifacts stay in build/gzip.

Run with build/oracle-uv/bin/python. --generate needs no native implementation;
--verify READER uses a freshly built coverage/read_table.mojo exporter.
"""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

import pyarrow as pa
import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).resolve().parent / 'coverage'))
from full_table import _arrow_export, inspect_full_table
from metadata_evidence import inspect_metadata_evidence

OUT = Path('build/gzip')


def stream_controls():
    directory = OUT / 'streams'
    directory.mkdir(parents=True, exist_ok=True)
    payload = bytes([42, 0, 0, 0])
    member = gzip.compress(payload, mtime=0)
    empty = gzip.compress(b'', mtime=0)
    # RFC 1952 FEXTRA/FNAME/FCOMMENT/FHCRC, CRC16 is low 16 bits of CRC32.
    header = b'\x1f\x8b\x08\x1e' + b'\0' * 4 + b'\0\xff'
    header += struct.pack('<H', 3) + b'xyz' + b'fixture\0comment\0'
    header += struct.pack('<H', zlib.crc32(header) & 65535)
    optional = header + member[10:]
    valid = {'member': member, 'empty': empty, 'optional': optional,
             'concatenated': empty + gzip.compress(payload[:2], mtime=0) + empty
                             + gzip.compress(payload[2:], mtime=0) + empty,
             'empty_members': empty * 3}
    bad = {'trailing': member + b'X', 'trailing_zero': member + b'\0',
           'next_member_truncated': member + empty[:-1],
           'next_member_invalid': member + b'\x1f\x8b\xff',
           'zlib_wrapper': zlib.compress(payload),
           'raw_deflate': zlib.compress(payload, wbits=-15),
           'bad_magic': b'\0' + member[1:],
           'bad_method': member[:2] + b'\0' + member[3:],
           'reserved_flags': member[:3] + b'\xe0' + member[4:],
           'crc': member[:-8] + bytes([member[-8] ^ 1]) + member[-7:],
           'isize': member[:-4] + struct.pack('<I', 5),
           'header_crc': optional[:31] + bytes([optional[31] ^ 1]) + optional[32:],
           'oversized': gzip.compress(b'A' * 1048576, mtime=0)}
    for n in range(len(member)):
        bad[f'truncated_{n}'] = member[:n]
    for name, data in {**valid, **bad}.items():
        (directory / (name + '.bin')).write_bytes(data)
    for name, data in valid.items():
        assert gzip.decompress(data) == (b'' if name in ('empty', 'empty_members') else payload)
    return {'valid': list(valid), 'invalid': list(bad), 'payload_hex': payload.hex()}


def table(count, mode):
    nullable = mode != 'required'
    types = [pa.int8(), pa.uint8(), pa.int16(), pa.uint16(), pa.int32(),
             pa.uint32(), pa.int64(), pa.uint64(), pa.float32(), pa.float64(),
             pa.bool_(), pa.binary(), pa.binary(4)]
    names = ['i8', 'u8', 'i16', 'u16', 'i32', 'u32', 'i64', 'u64', 'f32',
             'f64', 'flag', 'raw', 'fixed']
    arrays = []
    for dtype in types:
        values = []
        for i in range(count):
            if mode == 'all_null' or (mode == 'mixed' and i % 7 == 0):
                values.append(None)
            elif pa.types.is_boolean(dtype):
                values.append(i % 2 == 0)
            elif pa.types.is_fixed_size_binary(dtype):
                values.append(bytes([i % 251, 0, 255, 77]))
            elif pa.types.is_binary(dtype):
                values.append(bytes([i % 251]) * (i % 19))
            elif pa.types.is_floating(dtype):
                values.append([0.0, -0.0, float('inf'), -float('inf'), 1.25, float('nan')][i % 6])
            elif pa.types.is_signed_integer(dtype):
                values.append(i % 101 - 50)
            else:
                values.append(i % 101)
        arrays.append(pa.array(values, type=dtype))
    schema = pa.schema([pa.field(n, t, nullable) for n, t in zip(names, types)])
    return pa.Table.from_arrays(arrays, schema=schema)


def generate():
    OUT.mkdir(parents=True, exist_ok=True)
    records = []
    cases = [('required', 257, False), ('mixed', 257, False),
             ('mixed', 257, True), ('all_null', 33, True), ('empty', 0, False)]
    for version in ['1.0', '2.0']:
        for mode, count, dictionary in cases:
            name = f'v{version[0]}_{mode}_{"dict" if dictionary else "plain"}'
            data = table(count, mode)
            path = OUT / (name + '.parquet')
            pq.write_table(data, path, compression='gzip', use_dictionary=dictionary,
                           data_page_version=version, row_group_size=113,
                           data_page_size=128, write_batch_size=16, write_statistics=True)
            records.append(record(path, data))
        path = OUT / f'v{version[0]}_scalar_required.parquet'
        data = table(257, 'required').drop(['fixed'])
        pq.write_table(data, path, compression='gzip', use_dictionary=False,
                       data_page_version=version, row_group_size=113,
                       data_page_size=128, write_batch_size=16)
        records.append(record(path, data))
        # Force observable dictionary-to-PLAIN fallback, not just a footer set.
        path = OUT / f'v{version[0]}_fallback.parquet'
        data = pa.table({'i32': pa.array(list(range(2048)), type=pa.int32())})
        pq.write_table(data, path, compression='gzip', use_dictionary=True,
                       data_page_version=version, dictionary_pagesize_limit=64,
                       write_batch_size=16, data_page_size=128)
        item = record(path, data)
        scans = item['metadata']['row_groups'][0]['columns'][0]['page_scan']['page_records']
        encodings = {p.get('data_page_header', p.get('data_page_header_v2', {})).get('encoding') for p in scans}
        assert {0, 8} <= encodings, encodings
        records.append(item)
    records.extend(float_payload_fixtures())
    manifest = dict(producer=f'PyArrow {pa.__version__}', fixtures=records, streams=stream_controls())
    (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(f'Generated {len(records)} independent Parquet fixtures and stream controls')


def float_payload_fixtures():
    records = []
    arrays = [
        pa.Array.from_buffers(pa.float32(), 4, [pa.py_buffer(bytes([13])),
            pa.py_buffer(struct.pack('<4I', 0x7FC12345, 0xDEADBEEF, 0x80000000, 0x7F800001))]),
        pa.Array.from_buffers(pa.float64(), 4, [pa.py_buffer(bytes([13])),
            pa.py_buffer(struct.pack('<4Q', 0x7FF8123456789ABC, 0xDEADBEEF, 0x8000000000000000, 0x7FF0000000000001))]),
    ]
    data = pa.Table.from_arrays(arrays, names=['f32', 'f64'])
    for version in ('1.0', '2.0'):
        path = OUT / f'v{version[0]}_float_payload.parquet'
        pq.write_table(data, path, compression='gzip', use_dictionary=False,
                       data_page_version=version, write_batch_size=4)
        records.append(record(path, data))
    return records


def record(path, data):
    expected = _arrow_export(data)
    assert _arrow_export(pq.ParquetFile(path).read()) == expected
    metadata = inspect_metadata_evidence(path)
    assert not [f for f in metadata['findings'] if data.num_rows or f['disposition'] != 'unresolved'], metadata['findings']
    footer = pq.ParquetFile(path).metadata
    for i in range(footer.num_row_groups):
        for j in range(footer.num_columns):
            assert footer.row_group(i).column(j).compression == 'GZIP'
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                expected=expected, metadata=metadata)


def verify(binary):
    manifest = json.loads((OUT / 'manifest.json').read_text())
    results = []
    for fixture in manifest['fixtures']:
        path = Path(fixture['path'])
        assert hashlib.sha256(path.read_bytes()).hexdigest() == fixture['sha256']
        result = inspect_full_table(path, binary, OUT / 'parity')
        # Compare directly with producer inputs in addition to the three readers.
        if result['native']['status'] == 'exported':
            from full_table import parse_native, compare_tables
            result['producer_input'] = compare_tables(fixture['expected'], parse_native(Path(result['native']['artifact']).read_text()))
        results.append(dict(path=str(path), result=result))
        print(path.name, result['native']['status'], {k: v['status'] for k, v in result['oracles'].items()})
    (OUT / 'parity.json').write_text(json.dumps(results, indent=2))
    assert all(r['result'].get('producer_input', {}).get('status') == 'pass' for r in results)
    assert all(r['result']['oracles']['pyarrow']['status'] == 'pass' for r in results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--generate', action='store_true')
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--float-payload', action='store_true')
    args = parser.parse_args()
    if args.generate:
        generate()
    if args.float_payload:
        path = OUT / 'manifest.json'
        manifest = json.loads(path.read_text())
        manifest['fixtures'] = [r for r in manifest['fixtures'] if 'float_payload' not in r['path']] + float_payload_fixtures()
        path.write_text(json.dumps(manifest, indent=2))
    if args.verify:
        verify(args.verify)
