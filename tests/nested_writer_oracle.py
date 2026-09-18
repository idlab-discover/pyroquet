"""Independent checks of native nested writer output (run native tests first).

No native round trip is used as a value oracle. Expected storage rows are defined
here independently. Actual page headers and decoded levels establish PLAIN value
encoding and RLE level encoding. Fastparquet errors/representation loss stay distinct.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import duckdb
import fastparquet
import pyarrow as pa
import pyarrow.parquet as pq

from nested_fixture_oracle import page_evidence, compare

ROOT = Path(__file__).resolve().parents[1]


def expected(path):
    if path.stem.endswith('-struct'):
        return pa.schema([pa.field('s', pa.struct([pa.field('x', pa.int32(), nullable=False)])), pa.field('literal.dot', pa.int32(), nullable=False)]), [{'s': None if i == 0 else {'x': i + 20}, 'literal.dot': i + 10} for i in range(3)]
    if path.stem.endswith('-long'):
        return pa.schema([pa.field('l', pa.list_(pa.field('element', pa.bool_(), nullable=False)), nullable=False)]), [{'l': []}, {'l': [i % 2 == 0 for i in range(10000)]}, {'l': []}]
    if '-all-' in path.name:
        children = {}
        for i, typ in enumerate((pa.int8(), pa.uint8(), pa.int16(), pa.uint16(),
                                 pa.int32(), pa.uint32(), pa.int64(), pa.uint64(),
                                 pa.float32(), pa.float64())):
            children[f'n{i}'] = (typ, [1, None, 2])
        children.update(b0=(pa.bool_(), [False, None, True]),
                        b1=(pa.binary(), [b'', None, b'\0\xff']),
                        b2=(pa.binary(2), [b'\1\2', None, b'\xff\0']))
        schema = pa.schema([pa.field('s', pa.struct([
            pa.field(name, pa.list_(pa.field('element', typ)))
            for name, (typ, _) in children.items()]), nullable=False)])
        rows = [{'s': {name: val for name in children}} for val in (None, [])]
        rows += [{'s': {name: [vals[0]] for name, (_, vals) in children.items()}},
                 {'s': {name: vals[1:] for name, (_, vals) in children.items()}}]
        return schema, rows
    if '-required-' in path.name:
        n = int(path.stem.rsplit('-', 1)[1])
        return pa.schema([pa.field('a.b', pa.list_(pa.field('element', pa.int64(), nullable=False)), nullable=False)]), [
            {'a.b': [i]} for i in range(n)]
    return pa.schema([pa.field('s', pa.struct([pa.field('l', pa.list_(pa.int32()))]))]), [
        {'s': None}, {'s': {'l': None}}, {'s': {'l': []}}, {'s': {'l': [42, None]}}]


def run():
    report = {'producer': 'pyroquet native nested writer', 'seed': None,
              'versions': {m.__name__: m.__version__ for m in (pa, duckdb, fastparquet)},
              'fixtures': []}
    for path in sorted((ROOT / 'build').glob('nested-write-*.parquet')):
        if 'too-small' in path.name:
            raise AssertionError('failed write published destination')
        schema, rows = expected(path)
        actual = pq.read_table(path)
        assert actual.schema.equals(schema), (path, actual.schema, schema)
        assert actual.to_pylist() == rows, path
        pages = page_evidence(path)
        assert all(p['value_encoding'] == 0 for p in pages)
        for page in pages:
            assert not page['continues_previous_row']
            if page['page_version'] == 2:
                assert page['declared_rows'] == page['row_starts']
                assert page['declared_nulls'] == page['level_entries'] - page['present_values']
        if path.name.startswith('nested-write-v'):
            assert [p['definition_levels'] for p in pages] == [[0, 1], [2], [4, 3]]
            assert [p['repetition_levels'] for p in pages] == [[0, 0], [0], [0, 1]]
        checks = compare(path)
        assert checks['duckdb'] == 'pass', checks
        if '-required-' in path.name:
            # No STRUCT parent validity exists to be lost by this representation.
            try:
                p = fastparquet.ParquetFile(path)
                got = p.to_pandas().to_dict('records')
                assert got == rows, (path, got, rows)
                checks['fastparquet'] = {'status': 'pass', 'values': 'complete lists, order, boundaries',
                                         'schema': 'canonical required LIST/required INT64 via independent footer'}
            except Exception as error:
                checks['fastparquet'] = {'status': 'reader_error', 'error': repr(error),
                                         'reason': 'literal dotted LIST name is treated as path by this reader'}
        report['fixtures'].append(dict(path=str(path.relative_to(ROOT)),
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(), schema=str(schema),
            expected_rows=repr(rows), pages=pages, oracles=checks))
    assert len(report['fixtures']) == 14
    out = ROOT / 'build/nested-writer-evidence.json'
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{len(report["fixtures"])} files: PyArrow + DuckDB exact values/schema checks complete; Fastparquet statuses recorded in {out}')


if __name__ == '__main__':
    run()
