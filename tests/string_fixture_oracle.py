"""STRING wire fixtures and complete-value three-reader parity (development only).

Run --generate, compile tests/test_string_io.mojo, then --verify BINARY.
All retained fixtures, page evidence and reader results live in build/strings/.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import subprocess

import duckdb
import fastparquet
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

from check_metadata import fields, parts, put, encode
from check_pages import T, thrift_bytes
from check_numeric_dictionary import packed
from nested_fixture_oracle import page_evidence

OUT = Path('build/strings')
VALUES = ['', 'ASCII', 'é', 'e\u0301', '中文', '😀', 'a\0b', '\0', '\U0010ffff']
NESTED_VALUES = [None, {'text': '', 'labels': []}, {'text': 'é', 'labels': None},
                 {'text': 'a\0b', 'labels': ['', None, 'é']},
                 {'text': '😀', 'labels': ['a\0b', '😀']}]


def page(kind, body, specific, codec=0, level_bytes=0):
    encoded = body
    if codec:
        suffix = body[level_bytes:]
        suffix = (pa.compress(suffix, codec='snappy').to_pybytes()
                  if codec == 1 else gzip.compress(suffix, mtime=0))
        encoded = body[:level_bytes] + suffix
    header = [(1, T.I32, kind), (2, T.I32, len(body)),
              (3, T.I32, len(encoded)),
              (5 if kind == 0 else 7 if kind == 2 else 8, T.STRUCT, specific)]
    header = thrift_bytes(header)
    return header + encoded, len(header) + len(body), kind


def plain(values):
    return b''.join(struct.pack('<I', len(v)) + v for v in values if v is not None)


def data(values, payload, version, codec, encoding=0):
    levels = packed([int(v is not None) for v in values], 1)
    if version == 1:
        return page(0, struct.pack('<I', len(levels)) + levels + payload,
                    [(1,T.I32,len(values)), (2,T.I32,encoding),
                     (3,T.I32,3), (4,T.I32,3)], codec)
    return page(3, levels + payload,
                [(1,T.I32,len(values)), (2,T.I32,values.count(None)),
                 (3,T.I32,len(values)), (4,T.I32,encoding),
                 (5,T.I32,len(levels)), (6,T.I32,0), (7,T.BOOL,bool(codec))],
                codec, len(levels))


def wire(pages, rows, codec=0, annotation='both', physical=6):
    footer = fields()
    schema, group, _, md = parts(footer)
    schema[1][:] = [(1,T.I32,physical), (3,T.I32,1), (4,T.STRING,b'text')]
    if physical == 7:
        schema[1].append((2,T.I32,1))
    if annotation in ('both', 'legacy', 'modern_wins', 'other_modern'):
        schema[1].append((6,T.I32,4 if annotation == 'modern_wins' else 0))
    if annotation in ('both', 'modern', 'modern_wins'):
        schema[1].append((10,T.STRUCT,[(1,T.STRUCT,[])]))
    if annotation == 'other_modern':
        schema[1].append((10,T.STRUCT,[(4,T.STRUCT,[])]))
    body = b''.join(p[0] for p in pages)
    raw_size = sum(p[1] for p in pages)
    data_offset = 4 + sum(len(p[0]) for p in pages[:1] if p[2] == 2)
    for field in [(1,T.I32,physical), (2,T.LIST,(T.I32,[0,3,8])),
                  (3,T.LIST,(T.STRING,[b'text'])), (4,T.I32,codec),
                  (5,T.I64,rows), (6,T.I64,raw_size), (7,T.I64,len(body)),
                  (9,T.I64,data_offset)]:
        put(md, field)
    if pages[0][2] == 2:
        put(md, (11,T.I64,4))
    put(group,(2,T.I64,raw_size))
    put(group,(3,T.I64,rows))
    put(footer,(3,T.I64,rows))

    def ordered(fs):
        for _, typ, val in fs:
            if typ == T.STRUCT:
                ordered(val)
            elif typ == T.LIST and val[0] == T.STRUCT:
                for child in val[1]:
                    ordered(child)
        fs.sort(key=lambda field: field[0])

    ordered(footer)
    return encode(footer, body)


def generate():
    OUT.mkdir(parents=True, exist_ok=True)
    records = []

    def record(path, values=None, reject=None):
        entry = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        if reject:
            entry['reject'] = reject
        else:
            entry['values'] = values
            entry['pages'] = page_evidence(path)
        records.append(entry)

    for version in (1, 2):
        for codec, compression in enumerate(('NONE', 'SNAPPY', 'GZIP')):
            nested_type = pa.struct([('text', pa.string()), ('labels', pa.list_(pa.string()))])
            pq.write_table(pa.table({'s': pa.array(NESTED_VALUES, type=nested_type)}),
                           OUT / f'arrow-nested-v{version}-c{codec}.parquet',
                           compression=compression, data_page_version=f'{version}.0',
                           use_dictionary=True, row_group_size=2, data_page_size=64)
            for mode in ('plain', 'dictionary', 'fallback', 'all_null', 'empty'):
                values = ([None if i % 7 == 0 else VALUES[i % len(VALUES)]
                           for i in range(137)] if mode != 'fallback' else
                          [f'{i}:😀' for i in range(257)])
                if mode == 'all_null':
                    values = [None] * 17
                if mode == 'empty':
                    values = []
                path = OUT / f'arrow-v{version}-c{codec}-{mode}.parquet'
                pq.write_table(pa.table({'text': pa.array(values, type=pa.string())}), path,
                               compression=compression, data_page_version=f'{version}.0',
                               use_dictionary=mode in ('dictionary', 'fallback'),
                               row_group_size=61 if mode != 'fallback' else 300,
                               write_batch_size=8, data_page_size=64,
                               dictionary_pagesize_limit=32)
                record(path, values)
                if mode == 'fallback':
                    encodings = {p['value_encoding'] for p in records[-1]['pages']}
                    assert {0, 8} <= encodings, (path, encodings)
            # Exact mixed dictionary/PLAIN wire coverage; labels include UTF-8 and NUL.
            entries = [b'', '中文'.encode(), b'a\0b']
            ids = [0, None, 2, 1, 2, None, 0]
            dictionary = page(2, plain(entries), [(1,T.I32,3),(2,T.I32,0)], codec)
            indexed = data(ids, b'\x02' + packed([i for i in ids if i is not None], 2), version, codec, 8)
            tail = ['😀'.encode(), None, b'']
            pages = [dictionary, indexed, data(tail, plain(tail), version, codec)]
            expected = [None if i is None else entries[i].decode() for i in ids]
            expected += [None if v is None else v.decode() for v in tail]
            for annotation in ('both', 'modern', 'legacy'):
                path = OUT / f'wire-v{version}-c{codec}-{annotation}.parquet'
                path.write_bytes(wire(pages, len(expected), codec, annotation))
                record(path, expected)
            bad = {'overlong': [b'\xc0\x80'], 'surrogate': [b'\xed\xa0\x80'],
                   'above_unicode': [b'\xf4\x90\x80\x80'], 'truncated': [b'\xe2\x82'],
                   'boundary_split': [b'\xc3', b'\xa9'], 'continuation': [b'\x80']}
            for name, values in bad.items():
                path = OUT / f'invalid-v{version}-c{codec}-{name}.parquet'
                path.write_bytes(wire([data(values, plain(values), version, codec)], len(values), codec))
                record(path, reject='malformed UTF-8')
            invalid_ids = data([3], b'\x02' + packed([3], 2), version, codec, 8)
            path = OUT / f'invalid-v{version}-c{codec}-dictionary-id.parquet'
            path.write_bytes(wire([dictionary, invalid_ids], 1, codec))
            record(path, reject='dictionary ID outside dictionary')
            bad_dictionary = page(2, plain([b'x', b'\xff']), [(1,T.I32,2),(2,T.I32,0)], codec)
            valid_id = data([0], b'\x01' + packed([0], 1), version, codec, 8)
            path = OUT / f'invalid-v{version}-c{codec}-unused-dictionary-utf8.parquet'
            path.write_bytes(wire([bad_dictionary, valid_id], 1, codec))
            record(path, reject='invalid UTF-8 in unused dictionary label')
    for physical in (1, 2, 0, 7):
        path = OUT / f'invalid-physical-{physical}.parquet'
        path.write_bytes(wire([data([b'x'], b'\0' * 8, 1, 0)], 1, physical=physical))
        record(path, reject='STRING incompatible physical type')
    path = OUT / 'invalid-legacy-utf8-modern-enum.parquet'
    path.write_bytes(wire([data([b'x'], plain([b'x']), 1, 0)], 1, annotation='other_modern'))
    record(path, reject='modern ENUM takes precedence over legacy UTF8 and remains unsupported')
    path = OUT / 'modern-string-legacy-enum.parquet'
    path.write_bytes(wire([data([b'x'], plain([b'x']), 1, 0)], 1, annotation='modern_wins'))
    record(path, ['x'])
    for encoding in ('DELTA_LENGTH_BYTE_ARRAY', 'DELTA_BYTE_ARRAY'):
        path = OUT / f'unsupported-{encoding}.parquet'
        pq.write_table(pa.table({'text': VALUES}), path, use_dictionary=False,
                       column_encoding=encoding, compression='NONE')
        record(path, reject='unsupported encoding')
    (OUT / 'manifest.json').write_text(json.dumps(records, indent=2))
    (OUT / 'versions.json').write_text(json.dumps(dict(pyarrow=pa.__version__,
        duckdb=duckdb.__version__, fastparquet=fastparquet.__version__, pandas=pd.__version__), indent=2))
    print(f'Generated {len(records)} retained STRING fixtures')


def verify_readers(path, expected):
    arrow = pq.read_table(path)
    assert arrow.schema.names == ['text'] and arrow.schema.field('text').type == pa.string()
    assert arrow.to_pydict() == {'text': expected}, path
    sql = duckdb.connect().execute('SELECT * FROM read_parquet(?)', [str(path)])
    duck_type = str(sql.description[0][1])
    duck_values = [r[0] for r in sql.fetchall()]
    if '-modern.' in path.name and duck_type == 'BLOB':
        assert duck_values == [None if v is None else v.encode() for v in expected], path
        duck_status = 'unsupported: modern-only STRING exposed as BLOB; exact bytes verified'
    else:
        assert duck_type == 'VARCHAR', (path, duck_type)
        assert duck_values == expected, path
        duck_status = 'pass'
    pf = fastparquet.ParquetFile(path)
    assert pf.fmd.schema[1].type == 6
    assert pf.fmd.num_rows == len(expected)
    assert pf.fmd.schema[1].repetition_type == 1 and arrow.schema.field('text').nullable
    arrow_md = pq.ParquetFile(path).metadata
    assert len(pf.row_groups) == arrow_md.num_row_groups
    assert sum(g.num_rows for g in pf.row_groups) == len(expected)
    for index, group in enumerate(pf.row_groups):
        assert group.num_rows == arrow_md.row_group(index).num_rows
        assert group.columns[0].meta_data.num_values == group.num_rows
    result = {'pyarrow': 'pass', 'duckdb': duck_status}
    frame = pf.to_pandas()
    actual = [None if pd.isna(v) else v for v in frame.text.tolist()]
    if actual == expected and all(v is None or isinstance(v, str) for v in actual):
        result['fastparquet'] = 'pass'
    elif ('-modern.' in path.name or path.name == 'modern-string-legacy-enum.parquet') and actual == [None if v is None else v.encode() for v in expected]:
        result['fastparquet'] = 'unsupported: modern-only STRING exposed as bytes; exact bytes verified'
    else:
        raise AssertionError((path, 'fastparquet values/types', actual, expected))
    return result


def verify(binary):
    records = json.loads((OUT / 'manifest.json').read_text())
    results = []
    for record in records:
        path = Path(record['path'])
        assert hashlib.sha256(path.read_bytes()).hexdigest() == record['sha256']
        run = subprocess.run([str(binary.resolve()), str(path)], capture_output=True, text=True)
        if 'reject' in record:
            assert run.returncode != 0 and 'Unhandled exception' in run.stdout + run.stderr, (path, run)
            reason = record['reject']
            diagnostic = ('UTF-8' if 'UTF-8' in reason else 'dictionary ID' if 'dictionary ID' in reason
                          else 'encoding' if reason == 'unsupported encoding'
                          else 'not a supported flat column')
            assert diagnostic in run.stdout + run.stderr, (path, diagnostic, run)
            results.append(dict(path=str(path), rejection=record['reject'], diagnostic=run.stdout + run.stderr))
            continue
        assert run.returncode == 0, (path, run.stdout, run.stderr)
        expected = record['values']
        lines = run.stdout.splitlines()
        assert lines[0] == f'rows {len(expected)} kind 15', (path, lines)
        assert lines[1:] == ['null' if v is None else 'bytes' + ''.join(f' {b}' for b in v.encode()) for v in expected], path
        results.append(dict(path=str(path), native='pass', oracles=verify_readers(path, expected)))
    # The native test runner writes each page-version/codec combination here.
    for version in (1, 2):
        for codec in (0, 1, 2):
            path = OUT / f'native-v{version}-c{codec}.parquet'
            expected = [None if i % 7 == 0 else VALUES[i % len(VALUES)] for i in range(37)]
            pf = fastparquet.ParquetFile(path)
            leaf = pf.fmd.schema[1]
            assert leaf.converted_type == 0 and leaf.logicalType.STRING is not None
            assert pq.ParquetFile(path).schema.column(0).physical_type == 'BYTE_ARRAY'
            results.append(dict(path=str(path), oracles=verify_readers(path, expected)))
            for nested_path in (Path(f'build/string-nested-v{version}-c{codec}.parquet'),
                                OUT / f'arrow-nested-v{version}-c{codec}.parquet'):
                arrow = pq.read_table(nested_path)
                assert arrow.to_pydict() == {'s': NESTED_VALUES}, nested_path
                assert arrow.schema.field('s').type.field('text').type == pa.string()
                assert arrow.schema.field('s').type.field('labels').type.value_type == pa.string()
                rows = duckdb.connect().execute('SELECT * FROM read_parquet(?)', [str(nested_path)]).fetchall()
                assert [r[0] for r in rows] == NESTED_VALUES, nested_path
                native_schema = fastparquet.ParquetFile(nested_path)
                for leaf in native_schema.fmd.schema:
                    if leaf.type is not None:
                        assert leaf.type == 6 and leaf.converted_type == 0 and leaf.logicalType.STRING is not None
                try:
                    frame = native_schema.to_pandas()
                except (TypeError, UnboundLocalError) as error:
                    expected_error = ((TypeError, 'an integer is required')
                        if version == 2 and nested_path.name.startswith('string-nested') or codec == 0
                        else (UnboundLocalError, "cannot access local variable 'defi' where it is not associated with a value"))
                    assert (type(error), str(error)) == expected_error, (nested_path, error)
                    results.append(dict(path=str(nested_path), oracles={'pyarrow': 'pass', 'duckdb': 'pass',
                        'fastparquet': f'unsupported: {type(error).__name__}: {error}; comparison is not a pass'}))
                    continue
                # Fastparquet flattens structs and does not reconstruct list<string>
                # nested in a struct. Keep the exact observed output in the report.
                actual = {name: [None if v is None or (isinstance(v, float) and pd.isna(v)) else v
                                 for v in frame[name].tolist()] for name in frame.columns}
                expected_flat = {'s.text': [None, '', 'é', 'a\0b', '😀'],
                                 's.labels': [None, [], None, ['', None, 'é'], ['a\0b', '😀']]}
                if actual == expected_flat:
                    fast_status = 'pass (flattened struct representation)'
                else:
                    assert actual == {'s.text': expected_flat['s.text'],
                        's.labels': [None, [None], [], ['', None, 'é'], ['a\0b', '😀']]}, (nested_path, actual)
                    fast_status = 'mismatch: nested empty/null list conflation; comparison is not a pass'
                results.append(dict(path=str(nested_path), oracles={'pyarrow': 'pass', 'duckdb': 'pass',
                                    'fastparquet': fast_status}, fastparquet_actual=actual))
    (OUT / 'parity.json').write_text(json.dumps(results, indent=2))
    print(f'{len(results)} STRING fixture/output results verified; retained in {OUT}/parity.json')
    for result in results:
        for reader, status in result.get('oracles', {}).items():
            if status != 'pass':
                print(result['path'], reader, status)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--generate', action='store_true')
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.generate:
        generate()
    if args.verify:
        verify(args.verify)
