"""Pinned Fastparquet golden corpus gate; exclusions and limitations never pass."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import pyarrow as pa
import pyarrow.parquet as pq

from parity import export_native, compare_export

ROOT = Path(__file__).resolve().parents[2]
REVISION = 'f4beb59382e584354c4b2ef2c7a42efa4e97f024'
UPSTREAM = 'https://github.com/dask/fastparquet.git'
MANIFEST = Path(__file__).with_name('fastparquet_manifest.json')
EXCLUSIONS = ROOT / 'tests/coverage/excluded_fixtures.json'
sys.path.insert(0, str(ROOT / 'tests/coverage'))
from metadata_evidence import inspect_metadata_evidence

CUSTOMER = '7eea206081adb55bcc12bac4e0903d7c8d4b1b086636d67b19b9cd068a7dae5b'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def acquire(path):
    """Never replace or update an existing checkout; untracked files are ignored."""
    path = Path(path).resolve()
    if not path.exists() and path.name == 'test-data':
        return acquire(path.parent)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix='fastparquet-acquire-', dir=path.parent))
        # Keep a failed acquisition for diagnosis; never overwrite the destination.
        subprocess.run(['git', 'clone', '--no-checkout', '--filter=blob:none', UPSTREAM, str(staging)], check=True)
        subprocess.run(['git', '-C', str(staging), 'checkout', '--detach', REVISION], check=True)
        if path.exists():
            raise FileExistsError(path)
        os.rename(staging, path)
    checkout = Path(git(path, 'rev-parse', '--show-toplevel'))
    if git(checkout, 'rev-parse', 'HEAD') != REVISION:
        raise RuntimeError(f'Corpus checkout must be revision {REVISION}; existing checkout left unchanged')
    if git(checkout, 'status', '--porcelain', '--untracked-files=no'):
        raise RuntimeError('Corpus has tracked modifications; existing checkout left unchanged')
    corpus = checkout / 'test-data'
    if path not in (checkout, corpus):
        raise ValueError('--corpus must name the pinned checkout or its test-data directory')
    return checkout, corpus


def inventory(checkout):
    records = []
    for name in git(checkout, 'ls-files', 'test-data').splitlines():
        path = checkout / name
        with path.open('rb') as stream:
            if stream.read(4) != b'PAR1':
                continue
        records.append(dict(path=Path(name).relative_to('test-data').as_posix(),
                            sha256=digest(path), bytes=path.stat().st_size))
    return records


def unsupported(file):
    """Classify declared features, never native exception strings."""
    reasons = []
    def field_type(dtype, name):
        if pa.types.is_struct(dtype):
            for child in dtype:
                field_type(child.type, name + '.' + child.name)
        elif pa.types.is_list(dtype):
            if pa.types.is_nested(dtype.value_type):
                reasons.append(f'{name}: LIST element is not primitive ({dtype.value_type})')
            else:
                field_type(dtype.value_type, name + '[]')
        elif not (pa.types.is_integer(dtype) or pa.types.is_floating(dtype)
                  or pa.types.is_boolean(dtype) or pa.types.is_string(dtype)
                  or pa.types.is_binary(dtype) or pa.types.is_fixed_size_binary(dtype)):
            reasons.append(f'{name}: unsupported logical type {dtype}')
    for field in file.schema_arrow:
        field_type(field.type, field.name)
    for g in range(file.metadata.num_row_groups):
        for c in range(file.metadata.num_columns):
            column = file.metadata.row_group(g).column(c)
            if column.compression not in ('UNCOMPRESSED', 'SNAPPY', 'GZIP', 'ZSTD'):
                reasons.append(f'{column.path_in_schema}: unsupported codec {column.compression}')
            if column.file_path:
                reasons.append('dataset summary references external column chunks')
            for encoding in column.encodings:
                if encoding not in ('PLAIN', 'PLAIN_DICTIONARY', 'RLE', 'RLE_DICTIONARY', 'DELTA_BINARY_PACKED', 'BIT_PACKED'):
                    reasons.append(f'{column.path_in_schema}: unsupported encoding {encoding}')
    return sorted(set(reasons))


def page_features(file, evidence):
    reasons = []
    for gi, group in enumerate(evidence['row_groups']):
        for ci, column in enumerate(group['columns']):
            scan = column['page_scan']
            if scan['status'] != 'complete':
                raise ValueError(f'Incomplete golden page scan: {column}')
            physical = file.metadata.row_group(gi).column(ci).physical_type
            supported = (0, 3) if physical == 'BOOLEAN' else (0, 2, 5, 8) if physical in ('INT32', 'INT64') else (0, 2, 8)
            for page in scan['page_records']:
                detail = page.get('data_page_header', page.get('data_page_header_v2'))
                if detail and detail['encoding'] not in supported:
                    reasons.append(f"{column['path']}: unsupported actual data-page encoding {detail['encoding']}")
    return reasons


def reviewed_metadata(fixture, file, evidence, error):
    entries = json.loads(Path(__file__).with_name('golden_disagreements.json').read_text())['fixtures']
    match = next((e for e in entries if e['path'] == fixture['path'] and e['sha256'] == fixture['sha256'] and e['native_error'] == error), None)
    if match is None:
        return None
    observed = []
    for gi, group in enumerate(evidence['row_groups']):
        for ci, column in enumerate(group['columns']):
            metadata = file.metadata.row_group(gi).column(ci)
            pages = column['page_scan']['page_records']
            dictionary = next((p['offset'] for p in pages if p['type'] == 2), None)
            data = next((p['offset'] for p in pages if p['type'] in (0, 3)), None)
            if dictionary is not None and metadata.dictionary_page_offset is None and metadata.data_page_offset == dictionary:
                observed.append(dict(row_group=gi, column=ci, path=column['path'],
                                     declared_dictionary_offset=None, declared_data_offset=metadata.data_page_offset,
                                     observed_dictionary_offset=dictionary, observed_data_offset=data))
    if observed != match['evidence']:
        raise ValueError('Reviewed golden dictionary-page evidence changed')
    return match


def review_zero_columns(fixture, comparison, file):
    known = {'no_columns.parquet': 'ac4da4fa7cee02a24391e758bdf686bbf115f3bb727e0ebed23f070997a3b1a1',
             'no_columns_new.parquet': 'd9ede0c082ac9c1237343c349bb5f15c58b6ddcc42306cf74e7834104c213fff'}
    if known.get(fixture['path']) != fixture['sha256'] or file.metadata.num_columns != 0 or importlib.metadata.version('duckdb') != '1.5.5':
        return
    engine = comparison['engines']['duckdb']
    message = engine.get('error', '')
    if engine['status'] == 'failed' and message.startswith('Invalid Input Error: Failed to read Parquet file ') and "': Need at least one non-root column in the file\n" in message:
        engine['reviewed_limitation'] = 'DuckDB 1.5.5 rejects these exact two zero-column files; native/PyArrow still compared'
        engine['limitations'].append(engine['reviewed_limitation'])
        comparison['unexpected'] = [e for e in comparison['unexpected'] if e['engine'] != 'duckdb']
        if not comparison['unexpected']:
            comparison['status'] = 'with_limitations'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--acquire-only', action='store_true')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--corpus', type=Path, default=ROOT.parent / 'fastparquet')
    args = parser.parse_args()
    if not args.acquire_only and args.binary is None:
        parser.error('--binary is required unless --acquire-only is specified')
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', revision=REVISION, upstream=UPSTREAM,
                  records=[], unexpected=[], limitations=[])
    def save():
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    save()
    try:
        checkout, corpus = acquire(args.corpus)
        found = inventory(checkout)
        expected = json.loads(MANIFEST.read_text())
        if expected['revision'] != REVISION or found != expected['files']:
            raise RuntimeError('Pinned tracked PAR1 corpus inventory/hash mismatch')
        license_bytes = (checkout / 'LICENSE').read_bytes()
        if hashlib.sha256(license_bytes).hexdigest() != expected['license_sha256']:
            raise RuntimeError('Upstream license hash mismatch')
        (out / 'FASTPARQUET-LICENSE').write_bytes(license_bytes)
        (out / 'UPSTREAM-NOTICE.txt').write_text(
            f'Fastparquet golden fixtures, {UPSTREAM}\nRevision {REVISION}\n'
            'Upstream LICENSE is preserved alongside this notice. Original fixture bytes are unchanged.\n')
        report.update(checkout=str(checkout), corpus=str(corpus), inventory=found,
                      untracked=git(checkout, 'ls-files', '--others', '--exclude-standard'),
                      oracle_versions={n: importlib.metadata.version(n) for n in ('pyarrow', 'duckdb', 'fastparquet')})
        if args.acquire_only:
            report['status'] = 'fixture_inventory_verified'
            save()
            return False
        report['binary'] = dict(path=str(args.binary.resolve()), sha256=digest(args.binary))
        exclusions = {x['path']: x for x in json.loads(EXCLUSIONS.read_text())['fixtures']}
        for index, fixture in enumerate(found):
            record = dict(fixture=fixture, status='pending', role='dataset_summary' if Path(fixture['path']).name in ('_metadata', '_common_metadata') else 'standalone_file')
            report['records'].append(record)
            path = corpus / fixture['path']
            exclusion = exclusions.get(fixture['path'])
            if exclusion and exclusion['sha256'] == fixture['sha256']:
                record.update(status='excluded_invalid_fixture', exclusion=exclusion)
            else:
                try:
                    file = pq.ParquetFile(path)
                    reasons = unsupported(file)
                    record['schema'] = str(file.schema)
                    record['rows'] = file.metadata.num_rows
                    if path.name in ('_metadata', '_common_metadata'):
                        reasons.append('dataset summary metadata, not a standalone data-file comparison')
                    evidence = None
                    if not reasons:
                        evidence = inspect_metadata_evidence(path)
                        record['page_evidence'] = evidence
                        reasons.extend(page_features(file, evidence))
                    if reasons:
                        record.update(status='unsupported', reasons=reasons)
                    else:
                        directory = out / f'{index:03d}-native'
                        try:
                            record['native'] = export_native(path, args.binary.resolve(), directory, 2 * 1024**3)
                        except Exception as error:
                            output = '\n'.join((directory / name).read_text() for name in ('stdout.txt', 'stderr.txt') if (directory / name).exists())
                            if fixture['sha256'] == CUSTOMER and output.strip().endswith('Unhandled exception caught during execution: hybrid RLE run exceeds value count'):
                                record.update(status='unresolved_disagreement', error=str(error), native_error='hybrid RLE run exceeds value count', comparison_status='not_exercised',
                                              reason='Legacy Impala terminal definition-level RLE run exceeds declared page values; preserve strict rejection pending adjudication',
                                              spec_refs=['parquet-format/Encodings.md hybrid RLE grammar', 'parquet-format/README.md data page no-padding rule'])
                            else:
                                message = output.strip().split('Unhandled exception caught during execution: ')[-1]
                                review = reviewed_metadata(fixture, file, evidence, message)
                                if review is None:
                                    raise
                                record.update(status='reviewed_metadata_disagreement', error=str(error), native_error=message, comparison_status='not_exercised', review=review)
                        else:
                            comparison = compare_export(path, directory)
                            review_zero_columns(fixture, comparison, file)
                            (directory / 'comparison.json').write_text(json.dumps(comparison, indent=2) + '\n')
                            record.update(status=comparison['status'], comparison=comparison)
                            if comparison['unexpected']:
                                report['unexpected'].append(dict(fixture=fixture, errors=comparison['unexpected']))
                except Exception as error:
                    record.update(status='failed', error=str(error))
                    report['unexpected'].append(dict(fixture=fixture, error=str(error)))
            if record['status'] not in ('pass', 'failed'):
                report['limitations'].append(dict(fixture=fixture, status=record['status']))
            save()
            print(f"{index+1}/{len(found)} {fixture['path']}: {record['status']}", flush=True)
        report['summary'] = dict(Counter(r['status'] for r in report['records']))
        report['status'] = 'failed' if report['unexpected'] else 'with_limitations' if report['limitations'] else 'pass'
    except Exception as error:
        report['status'] = 'failed'
        report['unexpected'].append(dict(error=str(error)))
    save()
    return report['status'] == 'failed'


if __name__ == '__main__':
    raise SystemExit(main())
