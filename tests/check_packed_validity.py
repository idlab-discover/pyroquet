"""Exact packed-validity consumer/wire checks; run with oracle-uv Python.

Uses precompiled roundtrip_binary probes, avoiding implicit dependency changes.
Retains every fixture, complete expected values, hashes and oracle limitations.
"""
import argparse
import hashlib
import json
import random
import struct
import subprocess
from pathlib import Path

import duckdb
import fastparquet
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from fastparquet.cencoding import ThriftObject, NumpyIO
from fastparquet.compression import decompress_data
from check_binary_wire import fixture, plain
from check_numeric_dictionary import packed, rle, page
from check_pages import T
import check_binary


def levels(bits, mixed):
    if mixed and len(bits) >= 16:
        # Complete initial RLE run, complete packed group, then packed tail.
        return rle(bits[0], 8, 1) + packed(bits[8:16], 1) + (packed(bits[16:], 1) if len(bits) > 16 else b'')
    encoded = bytearray(packed(bits, 1))
    if len(bits) % 8:
        # Legal nonzero encoded tail padding must not affect present count.
        encoded[-1] |= (255 << (len(bits) % 8)) & 255
    return bytes(encoded)


def scalar_levels(data, count):
    result, at = [], 0
    while at < len(data):
        header, shift = 0, 0
        while True:
            value = data[at]
            at += 1
            header |= (value & 127) << shift
            if value < 128:
                break
            shift += 7
        if header & 1:
            size = header >> 1
            for value in data[at:at + size]:
                result.extend((value >> bit) & 1 for bit in range(8))
            at += size
        else:
            result.extend([data[at]] * (header >> 1))
            at += 1
    assert at == len(data) and count <= len(result) <= count + 7
    return result[:count]


def payload(name, values):
    present = [v for v in values if v is not None]
    if name == 'flag':
        return sum(int(v) << i for i, v in enumerate(present)).to_bytes((len(present) + 7) // 8, 'little')
    if name == 'number':
        return b''.join(struct.pack('<i', v) for v in present)
    return plain(values, name == 'fixed')


def make_page(name, values, version, codec, level_data):
    body = payload(name, values)
    if version == 1:
        return page(0, struct.pack('<I', len(level_data)) + level_data + body,
                    [(1,T.I32,len(values)),(2,T.I32,0),(3,T.I32,3),(4,T.I32,3)], codec)
    return page(3, level_data + body,
                [(1,T.I32,len(values)),(2,T.I32,values.count(None)),(3,T.I32,len(values)),
                 (4,T.I32,0),(5,T.I32,len(level_data)),(6,T.I32,0),(7,T.BOOL,bool(codec))], codec, len(level_data))


def wire(path, name, page_values):
    raw = path.read_bytes()
    pf = fastparquet.ParquetFile(path)
    md = pf.row_groups[0].columns[0].meta_data
    stream = NumpyIO(raw)
    stream.seek(md.data_page_offset)
    for values in page_values:
        header = ThriftObject.from_buffer(stream, 'PageHeader')
        body = raw[stream.tell():stream.tell() + header.compressed_page_size]
        stream.seek(stream.tell() + len(body))
        dh = header.data_page_header if header.type == 0 else header.data_page_header_v2
        assert dh.num_values == len(values)
        if header.type == 0:
            body = bytes(decompress_data(body, header.uncompressed_page_size, md.codec))
            size = int.from_bytes(body[:4], 'little')
            definition, values_raw = body[4:4 + size], body[4 + size:]
        else:
            size = dh.definition_levels_byte_length
            definition, values_raw = body[:size], body[size:]
            if dh.is_compressed:
                values_raw = bytes(decompress_data(values_raw, header.uncompressed_page_size - size, md.codec))
            assert dh.num_nulls == values.count(None) and dh.num_rows == len(values)
        assert scalar_levels(definition, len(values)) == [int(v is not None) for v in values]
        assert values_raw == payload(name, values)
    assert stream.tell() == md.data_page_offset + md.total_compressed_size


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=Path('build/packed-validity/parity'))
    parser.add_argument('--binary', action='append', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    records, limitations = [], []
    rng = random.Random(20260918)
    db = duckdb.connect()
    kinds = {'number': (1, pa.int32()), 'flag': (0, pa.bool_()),
             'raw': (6, pa.binary()), 'fixed': (7, pa.binary(3))}
    for version in (1, 2):
        for codec in (0, 1):
            for name, (physical, arrow_type) in kinds.items():
                for pattern in ('zero', 'one', 'alternating', 'random', 'mixed'):
                    pages, page_values = [], []
                    for n in [1,2,3,4,5,6,7,8,63,64,65,511,512,513]:
                        bits = [0 if pattern == 'zero' else 1 if pattern == 'one' else
                                i % 2 if pattern == 'alternating' else rng.randrange(2) for i in range(n)]
                        if pattern == 'mixed' and n >= 16:
                            bits[:8] = [1] * 8
                        values = [None if not bit else (i % 3 == 0 if name == 'flag' else
                                  i - 200 if name == 'number' else
                                  bytes([i % 256, 0, 255]) if name == 'fixed' else
                                  [b'', b'\0\xff', b'abc\x80'][i % 3]) for i, bit in enumerate(bits)]
                        page_values.append(values)
                        pages.append(make_page(name, values, version, codec, levels(bits, pattern == 'mixed')))
                    expected = sum(page_values, [])
                    path = args.out / f'{name}-{pattern}-v{version}-c{codec}.parquet'
                    path.write_bytes(fixture(name, physical, pages, len(expected), codec, 3 if name == 'fixed' else 0))
                    (args.out / 'current-case.json').write_text(json.dumps({'file': path.name, 'expected': [v.hex() if isinstance(v, bytes) else v for v in expected]}, indent=2))
                    for binary in args.binary:
                        check_binary.BINARY = binary.resolve()
                        check_binary.native(path, {name: expected})
                    wire(path, name, page_values)
                    arrow = pq.read_table(path)
                    assert arrow.schema.names == [name] and arrow.schema.field(name).type == arrow_type
                    assert arrow.to_pydict() == {name: expected}
                    result = db.execute('SELECT * FROM read_parquet(?)', [str(path)])
                    assert str(result.description[0][1]) == {'number':'INTEGER','flag':'BOOLEAN','raw':'BLOB','fixed':'BLOB'}[name]
                    assert result.fetchall() == [(v,) for v in expected]
                    pf = fastparquet.ParquetFile(path)
                    assert pf.columns == [name] and pf.schema.schema_element([name]).type == physical
                    try:
                        frame = pf.to_pandas()
                        actual = [None if pd.isna(v) else v for v in frame[name].tolist()]
                        assert actual == expected, (path, actual)
                        fp_status = 'pass'
                    except (IndexError, ValueError, TypeError) as exc:
                        # Preserve a public-reader failure; never label a skipped comparison pass.
                        assert version == 2, (path, exc)
                        assert (name in ('number', 'flag') and isinstance(exc, (IndexError, ValueError))) or (name in ('raw', 'fixed') and any(all(v is None for v in vs) for vs in page_values) and type(exc) is TypeError and str(exc) == 'an integer is required'), (path, exc)
                        fp_status = 'defect'
                        limitations.append({'file': path.name, 'reader': 'fastparquet public', 'error': repr(exc)})
                        # Localize the known multi-page V2 failure using complete standalone pages.
                        for i, (encoded, values) in enumerate(zip(pages, page_values)):
                            single = args.out / f'{path.stem}-page{i}.parquet'
                            single.write_bytes(fixture(name, physical, [encoded], len(values), codec, 3 if name == 'fixed' else 0))
                            try:
                                frame = fastparquet.ParquetFile(single).to_pandas()
                                assert [None if pd.isna(v) else v for v in frame[name].tolist()] == values, single
                            except TypeError as page_exc:
                                assert name in ('raw', 'fixed') and all(v is None for v in values) and str(page_exc) == 'an integer is required', (single, page_exc)
                                limitations.append({'file': single.name, 'reader': 'fastparquet single-page public', 'error': repr(page_exc)})
                    records.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                    'expected': [v.hex() if isinstance(v, bytes) else v for v in expected],
                                    'native': [str(p) for p in args.binary], 'wire': 'pass', 'pyarrow': 'pass',
                                    'duckdb': 'pass', 'fastparquet_public': fp_status})
                    (args.out / 'results.json').write_text(json.dumps({'fixtures': records, 'limitations': limitations}, indent=2))
    result = {'fixtures': records, 'limitations': limitations,
              'versions': {'pyarrow': pa.__version__, 'duckdb': duckdb.__version__, 'fastparquet': fastparquet.__version__}}
    (args.out / 'results.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({'fixtures': len(records), 'limitations': limitations}, indent=2))


if __name__ == '__main__':
    main()
