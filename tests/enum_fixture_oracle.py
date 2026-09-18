"""Genuine ENUM wire fixtures and explicit three-reader interoperability results.

Generated files retain their original page bytes; footer annotation changes are
intentional fixture construction, not claims that Arrow emits ENUM itself.
"""
import argparse
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

import string_fixture_oracle as strings
from string_fixture_oracle import VALUES, NESTED_VALUES, page, plain, data, packed, T
from nested_fixture_oracle import page_evidence

OUT = Path('build/enums')


def annotate(path, annotation='both', invalid_physical=False):
    raw = path.read_bytes()
    pf = fastparquet.ParquetFile(path)
    for leaf in pf.fmd.schema:
        if leaf.type == 6 or (invalid_physical and leaf.type is not None):
            leaf.converted_type = None if annotation == 'modern' else 4
            leaf.logicalType = None if annotation == 'legacy' else {4: {}}
            if annotation == 'modern_wins':
                leaf.converted_type = 0
    # An embedded Arrow schema would describe the precursor, not this fixture.
    pf.fmd.key_value_metadata = None
    start = len(raw) - 8 - struct.unpack_from('<I', raw, len(raw) - 8)[0]
    footer = bytes(pf.fmd.to_bytes())
    path.write_bytes(raw[:start] + footer + struct.pack('<I', len(footer)) + b'PAR1')


def generate():
    OUT.mkdir(parents=True, exist_ok=True)
    records = []

    def record(path, values=None, reject=None):
        record = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        if reject:
            record['reject'] = reject
        else:
            leaf = fastparquet.ParquetFile(path).fmd.schema[1]
            assert leaf.type == 6
            if leaf.logicalType is not None:
                assert leaf.logicalType.ENUM is not None and leaf.logicalType.STRING is None
            else:
                assert leaf.converted_type == 4
            record.update(values=values, pages=page_evidence(path))
        records.append(record)

    for version in (1, 2):
        for codec, compression in enumerate(('NONE', 'SNAPPY', 'GZIP')):
            for mode in ('plain', 'dictionary', 'fallback', 'all_null', 'empty', 'rowgroups'):
                values = [None if i % 7 == 0 else VALUES[i % len(VALUES)] for i in range(137)]
                if mode == 'fallback':
                    values = [f'{i}:😀' for i in range(257)]
                elif mode == 'all_null':
                    values = [None] * 17
                elif mode == 'empty':
                    values = []
                elif mode == 'rowgroups':
                    values = ['a', 'b', None, 'b', 'a', 'c', 'd', 'e', 'd']
                path = OUT / f'arrow-v{version}-c{codec}-{mode}.parquet'
                pq.write_table(pa.table({'text': pa.array(values, type=pa.string())}), path,
                    compression=compression, data_page_version=f'{version}.0',
                    use_dictionary=mode in ('dictionary', 'fallback', 'rowgroups'),
                    row_group_size=3 if mode == 'rowgroups' else 300 if mode == 'fallback' else 61,
                    write_batch_size=8, data_page_size=64, dictionary_pagesize_limit=32)
                annotate(path)
                record(path, values)
                if mode == 'fallback':
                    assert {0, 8} <= {p['value_encoding'] for p in records[-1]['pages']}
            # Duplicate source labels, out-of-order references and a PLAIN tail.
            entries = [b'', '中文'.encode(), b'a\0b', '中文'.encode()]
            ids = [3, None, 2, 1, 2, None, 0]
            dictionary = page(2, plain(entries), [(1,T.I32,4),(2,T.I32,0)], codec)
            indexed = data(ids, b'\x02' + packed([i for i in ids if i is not None], 2), version, codec, 8)
            tail = ['😀'.encode(), None, b'']
            pages = [dictionary, indexed, data(tail, plain(tail), version, codec)]
            expected = [None if i is None else entries[i].decode() for i in ids]
            expected += [None if v is None else v.decode() for v in tail]
            for annotation in ('both', 'modern', 'legacy', 'modern_wins'):
                path = OUT / f'wire-v{version}-c{codec}-{annotation}.parquet'
                path.write_bytes(strings.wire(pages, len(expected), codec))
                annotate(path, annotation)
                record(path, expected)
            bad = {'overlong': [b'\xc0\x80'], 'surrogate': [b'\xed\xa0\x80'],
                   'above_unicode': [b'\xf4\x90\x80\x80'], 'truncated': [b'\xe2\x82'],
                   'boundary_split': [b'\xc3', b'\xa9'], 'continuation': [b'\x80']}
            for name, values in bad.items():
                path = OUT / f'invalid-v{version}-c{codec}-{name}.parquet'
                path.write_bytes(strings.wire([data(values, plain(values), version, codec)], len(values), codec))
                annotate(path)
                record(path, reject='UTF-8')
            path = OUT / f'invalid-v{version}-c{codec}-dictionary-id.parquet'
            path.write_bytes(strings.wire([dictionary, data([4], b'\x03' + packed([4], 3), version, codec, 8)], 1, codec))
            annotate(path)
            record(path, reject='dictionary ID')
            bad_dictionary = page(2, plain([b'x', b'\xff']), [(1,T.I32,2),(2,T.I32,0)], codec)
            path = OUT / f'invalid-v{version}-c{codec}-unused-dictionary-utf8.parquet'
            path.write_bytes(strings.wire([bad_dictionary, data([0], b'\x01' + packed([0], 1), version, codec, 8)], 1, codec))
            annotate(path)
            record(path, reject='UTF-8')
            path = OUT / f'arrow-nested-v{version}-c{codec}.parquet'
            nested = pa.struct([('text', pa.string()), ('labels', pa.list_(pa.string()))])
            pq.write_table(pa.table({'s': pa.array(NESTED_VALUES, type=nested)}), path,
                compression=compression, data_page_version=f'{version}.0', use_dictionary=True, row_group_size=2)
            annotate(path)
    for physical in (0, 1, 2, 7):
        path = OUT / f'invalid-physical-{physical}.parquet'
        path.write_bytes(strings.wire([data([b'x'], b'\0' * 8, 1, 0)], 1,
                                     physical=physical))
        annotate(path, invalid_physical=True)
        record(path, reject='not a supported flat column')
    for encoding in ('DELTA_LENGTH_BYTE_ARRAY', 'DELTA_BYTE_ARRAY'):
        path = OUT / f'unsupported-{encoding}.parquet'
        pq.write_table(pa.table({'text': VALUES}), path, use_dictionary=False,
                       column_encoding=encoding, compression='NONE')
        annotate(path)
        record(path, reject='encoding')
    control = OUT / 'dictionary-string-control.parquet'
    pq.write_table(pa.table({'text': pa.array(VALUES).dictionary_encode()}), control)
    leaf = fastparquet.ParquetFile(control).fmd.schema[1]
    assert leaf.converted_type == 0 and leaf.logicalType.STRING is not None
    (OUT / 'manifest.json').write_text(json.dumps(records, indent=2))
    (OUT / 'versions.json').write_text(json.dumps(dict(pyarrow=pa.__version__, duckdb=duckdb.__version__,
        fastparquet=fastparquet.__version__, pandas=pd.__version__), indent=2))
    print(f'Generated {len(records)} genuine ENUM fixtures and six nested fixtures')


def verify_readers(path, expected):
    pf = fastparquet.ParquetFile(path)
    leaf = pf.fmd.schema[1]
    assert leaf.type == 6
    assert leaf.converted_type == 4 or leaf.logicalType.ENUM is not None
    assert pf.fmd.num_rows == len(expected)
    am = pq.ParquetFile(path).metadata
    assert am.num_rows == len(expected) and am.num_row_groups == len(pf.row_groups)
    for i, group in enumerate(pf.row_groups):
        assert group.num_rows == am.row_group(i).num_rows
        assert group.columns[0].meta_data.num_values == group.num_rows
    result = {}

    def compare(reader, values, type_name, text_type):
        if values == expected and text_type:
            result[reader] = dict(status='pass', type=type_name)
        else:
            assert values == [None if v is None else v.encode() for v in expected], (path, reader, values)
            result[reader] = dict(status='unsupported: ENUM exposed as binary; exact bytes verified; not a pass', type=type_name)

    arrow = pq.read_table(path)
    assert arrow.schema.names == ['text'] and arrow.schema.field('text').nullable
    compare('pyarrow', arrow.column(0).to_pylist(), str(arrow.column(0).type), arrow.column(0).type == pa.string())
    with duckdb.connect() as con:
        cursor = con.execute('SELECT * FROM read_parquet(?)', [str(path)])
        typ = str(cursor.description[0][1])
        compare('duckdb', [r[0] for r in cursor.fetchall()], typ, typ == 'VARCHAR')
    frame = pf.to_pandas()
    actual = [None if pd.isna(v) else v for v in frame.text.tolist()]
    compare('fastparquet', actual, str(frame.text.dtype), all(v is None or isinstance(v, str) for v in actual))
    return result


def verify(binary):
    results = []
    for record in json.loads((OUT / 'manifest.json').read_text()):
        path = Path(record['path'])
        assert hashlib.sha256(path.read_bytes()).hexdigest() == record['sha256']
        run = subprocess.run([str(binary.resolve()), str(path)], capture_output=True, text=True)
        if 'reject' in record:
            assert run.returncode != 0 and 'Unhandled exception' in run.stdout + run.stderr, (path, run)
            assert record['reject'] in run.stdout + run.stderr, (path, run)
            results.append(dict(path=str(path), rejection=record['reject'], diagnostic=run.stdout + run.stderr))
            continue
        assert run.returncode == 0, (path, run.stdout, run.stderr)
        expected = record['values']
        lines = run.stdout.splitlines()
        assert lines[0] == f'rows {len(expected)} kind 16', (path, lines)
        assert lines[1:] == ['null' if v is None else 'bytes' + ''.join(f' {b}' for b in v.encode()) for v in expected], path
        results.append(dict(path=str(path), native='pass', oracles=verify_readers(path, expected)))
    for version in (1, 2):
        for codec in (0, 1, 2):
            path = OUT / f'native-v{version}-c{codec}.parquet'
            leaf = fastparquet.ParquetFile(path).fmd.schema[1]
            assert leaf.converted_type == 4 and leaf.logicalType.ENUM is not None
            assert {p['value_encoding'] for p in page_evidence(path)} == {0}
            expected = [None if i % 7 == 0 else VALUES[i % len(VALUES)] for i in range(37)]
            results.append(dict(path=str(path), oracles=verify_readers(path, expected)))
            for nested_path in (Path(f'build/enum-nested-v{version}-c{codec}.parquet'),
                                OUT / f'arrow-nested-v{version}-c{codec}.parquet'):
                results.append(verify_nested(nested_path, version, codec))
    (OUT / 'parity.json').write_text(json.dumps(results, indent=2))
    print(f'{len(results)} ENUM results retained in {OUT}/parity.json')


def _bytes(value):
    if isinstance(value, str):
        return value.encode()
    if isinstance(value, list):
        return [_bytes(v) for v in value]
    if isinstance(value, dict):
        return {k: _bytes(v) for k, v in value.items()}
    return value


def verify_nested(path, version, codec):
    pf = fastparquet.ParquetFile(path)
    for leaf in pf.fmd.schema:
        if leaf.type is not None:
            assert leaf.type == 6 and leaf.converted_type == 4 and leaf.logicalType.ENUM is not None
    arrow = pq.read_table(path)
    assert arrow.to_pydict() == {'s': _bytes(NESTED_VALUES)}, path
    assert arrow.schema.field('s').type.field('text').type == pa.binary()
    assert arrow.schema.field('s').type.field('labels').type.value_type == pa.binary()
    with duckdb.connect() as con:
        cursor = con.execute('SELECT * FROM read_parquet(?)', [str(path)])
        assert str(cursor.description[0][1]) == 'STRUCT("text" VARCHAR, labels VARCHAR[])'
        assert [r[0] for r in cursor.fetchall()] == NESTED_VALUES, path
    result = dict(path=str(path), oracles={
        'pyarrow': dict(status='unsupported: ENUM exposed as binary; complete nested bytes verified; not a pass', type=str(arrow.schema)),
        'duckdb': dict(status='pass', type='STRUCT(text VARCHAR, labels VARCHAR[])')})
    try:
        frame = pf.to_pandas()
    except (TypeError, UnboundLocalError) as error:
        expected = ((TypeError, 'an integer is required')
            if version == 2 and path.name.startswith('enum-nested') or codec == 0 else
            (UnboundLocalError, "cannot access local variable 'defi' where it is not associated with a value"))
        assert (type(error), str(error)) == expected, (path, error)
        result['oracles']['fastparquet'] = dict(status=f'unsupported: {type(error).__name__}: {error}; not a pass')
        return result
    actual = {name: [None if v is None or isinstance(v, float) and pd.isna(v) else v
                     for v in frame[name].tolist()] for name in frame.columns}
    assert actual == _bytes({'s.text': [None, '', 'é', 'a\0b', '😀'],
        's.labels': [None, [None], [], ['', None, 'é'], ['a\0b', '😀']]}), (path, actual)
    result['oracles']['fastparquet'] = dict(status='mismatch: ENUM binary fallback and nested empty/null list conflation; not a pass',
        actual_repr=repr(actual), types={name: str(frame[name].dtype) for name in frame.columns})
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--generate', action='store_true')
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.generate:
        generate()
    if args.verify:
        verify(args.verify)
