"""Independent expected values plus central parity for exact native flat and nested outputs."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys

import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
from nested_writer_oracle import expected as nested_expected
from string_fixture_oracle import VALUES as STRING_VALUES, NESTED_VALUES as STRING_NESTED
from enum_fixture_oracle import VALUES as ENUM_VALUES, NESTED_VALUES as ENUM_NESTED, _bytes
from parity import export_native, compare_export

EXPECTED = ([f'nested-write-v{v}-c{c}.parquet' for v in (1, 2) for c in (0, 1, 2, 6)]
            + [f'nested-write-all-v{v}.parquet' for v in (1, 2)]
            + [f'nested-write-required-{rows}.parquet' for rows in range(4)]
            + ['nested-write-struct.parquet', 'nested-write-long.parquet']
            + [f'{kind}s/native-v{v}-c{c}.parquet' for kind in ('string','enum') for v in (1,2) for c in (0,1,2,6)]
            + [f'{kind}-nested-v{v}-c{c}.parquet' for kind in ('string','enum') for v in (1,2) for c in (0,1,2,6)])


def expected(path):
    if path.name.startswith('nested-write-'):
        return nested_expected(path)
    enum = path.parent.name=='enums' or path.name.startswith('enum-')
    dtype = pa.binary() if enum else pa.string()
    if path.name.startswith('native-'):
        values = ENUM_VALUES if enum else STRING_VALUES
        rows = [dict(text=None if i%7==0 else values[i%len(values)]) for i in range(37)]
        if enum: rows=_bytes(rows)
        return pa.schema([pa.field('text',dtype)]),rows
    schema=pa.schema([pa.field('s',pa.struct([pa.field('text',dtype),pa.field('labels',pa.list_(dtype))]))])
    values = _bytes(ENUM_NESTED) if enum else STRING_NESTED
    return schema,[dict(s=value) for value in values]


def run(binary, out):
    out = Path(out); out.mkdir(parents=True, exist_ok=False)
    catalog = json.loads(Path(__file__).with_name('writer_limitations.json').read_text())['fixtures']
    report = dict(status='running', fixtures=[], limitations=[], unexpected=[])
    for name in EXPECTED:
        path = ROOT / 'build' / name
        # Required explicit paths: missing writer cases must fail, never silently skip.
        raw = path.read_bytes(); sha = hashlib.sha256(raw).hexdigest()
        schema, rows = expected(path)
        table = pq.read_table(path)
        if not table.schema.equals(schema) or table.to_pylist() != rows:
            raise AssertionError(f'Independent expected schema/values differ: {path}')
        export = out / name.replace('/', '-')
        export_native(path, binary, export, 256 * 1024 * 1024)
        result = compare_export(path, export)
        if result['unexpected']:
            known = next((r for r in catalog if r['path'] == name and r['sha256'] == sha
                          and r['version'] == importlib.metadata.version('fastparquet')), None)
            if (known is None or result['unexpected'] != [dict(engine='fastparquet', error=known['error'])]
                    or result['engines']['pyarrow']['dimensions'].get('values') != 'pass'
                    or result['engines']['duckdb']['dimensions'].get('values') != 'pass'):
                raise AssertionError(dict(path=str(path), result=result))
            oracle = result['engines']['fastparquet']
            oracle['observed_failure'] = dict(error=oracle['error'], fixture_sha256=sha)
            oracle['status'] = 'reviewed_limitation'
            oracle['limitations'].append(known['reason'])
            oracle['dimensions'].update(values='not established: reviewed reader mismatch/error',
                                        nulls='not established', order='not established')
            result['limitations'].append(dict(engine='fastparquet', reason=known['reason'], evidence=known))
            result['unexpected'] = []
            result['status'] = 'with_limitations'
        result_path = export / 'report.json'
        result_path.write_text(json.dumps(result, indent=2) + '\n')
        report['fixtures'].append(dict(path=str(path), sha256=sha, independent_expected='pass',
                                       result=result, report=str(result_path),
                                       report_sha256=hashlib.sha256(result_path.read_bytes()).hexdigest()))
        report['limitations'].extend(result['limitations'])
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if len(report['fixtures']) != len(EXPECTED):
        raise AssertionError('Incomplete native flat/nested writer coverage')
    report['status'] = 'with_limitations' if report['limitations'] else 'pass'
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    result = run(args.binary, args.out)
    print(json.dumps(dict(status=result['status'], fixtures=len(result['fixtures']),
                         limitations=len(result['limitations']))))
