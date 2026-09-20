"""Exact, reproducible Fastparquet V2 required-LIST PLAIN limitation controls.

Only the hash-pinned medium/large mixed fixtures and the observed broadcast failure are
eligible. Controls inspect one 65,536-row group, never read the large file whole.
The caller must independently require complete native/Arrow/DuckDB agreement.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import hashlib
import importlib.metadata
import json
from pathlib import Path

import fastparquet
import pyarrow.parquet as pq

from fixtures import CODECS, options, page_evidence

SOURCES = {
    'large-mixed-v2-c6.parquet': ('d937c16d03724386a46b4385ce82a9b32fd2be1f3bd768c56ee7839d3be6e639', 60),
    'medium-mixed-v2-c1.parquet': ('2ca2dccac214b63b60ba28a19610fffd1b118f4394639ccba7a7c53ff97e4c90', 3),
}
ERROR = 'could not broadcast input array from shape (40000,) into shape (25536,)'
VERSIONS = {'fastparquet': '2026.5.0', 'numpy': '2.5.3', 'pyarrow': '25.0.1'}


def _signature(path):
    stat = path.stat()
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)


@lru_cache(maxsize=16)
def _digest(path, signature):
    with Path(path).open('rb') as stream:
        result = hashlib.file_digest(stream, 'sha256').hexdigest()
    if _signature(Path(path)) != signature:
        raise ValueError('File changed while hashing: ' + path)
    return result


def digest(path):
    path = Path(path).resolve()
    return _digest(str(path), _signature(path))


def _eligible(source):
    return (source.name in SOURCES
            and all(importlib.metadata.version(name) == value for name, value in VERSIONS.items())
            and digest(source) == SOURCES[source.name][0])


def _probe(path, expected, version):
    # No generic exception masking: only this exact observed ValueError is known.
    try:
        with Path(path).open('rb') as stream:
            actual = fastparquet.ParquetFile(stream).to_pandas(columns=['items'])['items'].tolist()
    except ValueError as error:
        if version != 2 or str(error) != ERROR:
            raise
        return {'status': 'reviewed_reader_error_not_pass', 'error_type': 'ValueError', 'error': str(error)}
    if version != 1:
        raise AssertionError('V2 control no longer reproduces the reviewed failure')
    if actual != expected:
        raise AssertionError('V1 control does not match every source list value')
    return {'status': 'pass', 'rows': len(expected), 'values_nulls_order': 'pass'}


def generate_controls(source: Path, out: Path) -> dict:
    source, out = Path(source).resolve(), Path(out).resolve()
    if not _eligible(source):
        raise ValueError('Unreviewed fixture hash or oracle versions')
    source_sha, groups = SOURCES[source.name]
    pf = pq.ParquetFile(source)
    if pf.metadata.num_row_groups != groups or pf.metadata.num_rows != groups * 65536:
        raise ValueError('Unexpected reviewed source layout')
    table = pf.read_row_group(0, columns=['items'])
    expected = table.column(0).to_pylist()
    if len(expected) != 65536 or any(value is None or len(value) != 2 or any(x is None for x in value) for value in expected):
        raise ValueError('Unexpected reviewed LIST structure')
    out.mkdir(parents=True, exist_ok=True)
    report_path = out / 'report.json'
    if report_path.exists():
        report = json.loads(report_path.read_text())
        if report.get('source_sha256') != source_sha or report.get('versions') != VERSIONS:
            raise ValueError('Stale LIST controls report')
        expected_controls = {(version, codec, f'first-rowgroup-v{version}-c{codec}.parquet')
                             for version in (1, 2) for codec in CODECS}
        if len(report.get('controls', [])) != 8 or {(c['page_version'], c['codec'], c['path']) for c in report['controls']} != expected_controls:
            raise ValueError('Incomplete LIST control matrix')
        for control in report['controls']:
            path = out / control['path']
            if digest(path) != control['sha256']:
                raise ValueError('Changed LIST control: ' + str(path))
            if not pq.read_table(path).equals(table):
                raise ValueError('Control differs from source first row group')
            if _probe(path, expected, control['page_version']) != control['fastparquet']:
                raise ValueError('Control oracle result changed')
        return report
    if any(out.iterdir()):
        raise ValueError('Partial LIST controls directory; choose a new directory')
    controls = []
    for version in (1, 2):
        for codec in CODECS:
            path = out / f'first-rowgroup-v{version}-c{codec}.parquet'
            settings = options(codec, version, False)
            pq.write_table(table, path, **settings)
            if not pq.read_table(path).equals(table):
                raise AssertionError('Arrow control failed complete source equality')
            controls.append(dict(path=path.name, sha256=digest(path), bytes=path.stat().st_size,
                                 page_version=version, codec=codec, settings=settings,
                                 pyarrow='pass', fastparquet=_probe(path, expected, version),
                                 pages=page_evidence(path)))
    report = dict(source=str(source), source_sha256=source_sha, versions=VERSIONS,
                  scope='first source row group, items column, complete values/nulls/order',
                  rows=65536, values=131072, controls=controls,
                  conclusion='V2 repeated PLAIN decoding fails independently of codec; V1 control passes',
                  library_values='not certified by Fastparquet for this column; reviewed nonpass')
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    return report


@lru_cache(maxsize=16)
def _controls_once(source, out, signature):
    report = generate_controls(Path(source), Path(out))
    return report, digest(Path(out) / 'report.json')


def review_large_list(path, column, group_index, error, out):
    """Return exact reviewed nonpass evidence, or None for any unknown case.

    Full source SHA is cached only while inode/size/mtime/ctime stay identical.
    Controls are independently rerun on the first call in every process; hashes
    are checked again for subsequent row groups.
    """
    path = Path(path).resolve()
    if path.name not in SOURCES or column != 'items' or not 0 <= group_index < SOURCES[path.name][1] or type(error) is not ValueError or str(error) != ERROR:
        return None
    if not _eligible(path):
        return None
    directory = Path(out).resolve() / 'large-list-controls'
    report, report_sha = _controls_once(str(path), str(directory), _signature(path))
    if digest(directory / 'report.json') != report_sha:
        raise ValueError('Reviewed LIST report changed during qualification')
    for control in report['controls']:
        if digest(directory / control['path']) != control['sha256']:
            raise ValueError('Reviewed LIST control changed during qualification')
    return dict(status='reviewed_disagreement_not_pass', column=column, row_group=group_index,
                error_type='ValueError', error=ERROR, fixture_sha256=SOURCES[path.name][0],
                review='Fastparquet V2 PLAIN repeated values assigned to row-sized output; V1 and codec-only controls',
                controls_report=str(directory / 'report.json'),
                controls_report_sha256=digest(directory / 'report.json'),
                controls=[dict(path=str(directory / c['path']), sha256=c['sha256'],
                               page_version=c['page_version'], codec=c['codec'],
                               status=c['fastparquet']['status']) for c in report['controls']])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    report = generate_controls(args.source, args.out)
    print(json.dumps({'controls': len(report['controls']), 'source_sha256': report['source_sha256'],
                      'report': str(args.out / 'report.json')}))
