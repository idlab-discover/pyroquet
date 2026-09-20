"""Fresh ZSTD read/write parity, including explicit independent-reader limitations."""
from pathlib import Path
import collections
import hashlib
from importlib.metadata import version as package_version
import json
import subprocess
import sys
import tempfile

import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).resolve().parent / 'coverage'))
from full_table import ROOT, build_reader, inspect_full_table, _arrow_export, compare_tables, parse_native
from metadata_evidence import inspect_metadata_evidence
from gzip_fixture_oracle import table


def review_errors(record, data, page_version, dictionary, writer):
    """Recognize only reviewed fixture hash/version/exact errors; keep nonpass."""
    import fastparquet
    oracle = record['result']['oracles']['fastparquet']
    if oracle['status'] != 'error':
        return
    reviewed = json.loads(Path(__file__).with_name('zstd_oracle_limitations.json').read_text())['limitations']
    match = next((item for item in reviewed if item['sha256'] == record['sha256']
                  and item['version'] == package_version('fastparquet')
                  and oracle['error'].splitlines()[-1] == item['error']), None)
    if match is None:
        return
    path = Path(record['path'])
    control = path.with_stem(path.stem + '-uncompressed-control')
    if path.stem.endswith('-native'):
        subprocess.run([str(writer), str(path), str(control), str(page_version), '0'], check=True)
    else:
        pq.write_table(data, control, compression='NONE', use_dictionary=dictionary,
                       data_page_version=f'{page_version}.0', row_group_size=113,
                       data_page_size=128, write_batch_size=16)
    if hashlib.sha256(control.read_bytes()).hexdigest() != match['control_sha256']:
        raise AssertionError('Reviewed control bytes changed')
    try:
        fastparquet.ParquetFile(control).to_pandas(columns=match['control_columns'])
    except (IndexError, ValueError) as error:
        if type(error).__name__ + ': ' + str(error) != match['error']:
            raise
    else:
        raise AssertionError('Reviewed control no longer reproduces')
    oracle['reviewed_limitation'] = match
    oracle['control'] = str(control)


def main():
    base = ROOT / 'build/zstd'
    base.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='parity-', dir=base))
    reader, writer = out / 'read-table', out / 'roundtrip'
    build_reader(binary=reader)
    build_reader(binary=writer, source='tests/roundtrip_mixed.mojo')
    records = []
    for version in (1, 2):
        for mode, count in [('required', 257), ('mixed', 257), ('all_null', 33), ('empty', 0), ('required_scalar', 257)]:
            for dictionary in (False, True):
                data = table(count, "required" if mode == "required_scalar" else mode)
                if mode == "required_scalar":
                    data = data.drop(["fixed"])
                source = out / f'v{version}-{mode}-{dictionary}.parquet'
                pq.write_table(data, source, compression='zstd', use_dictionary=dictionary,
                               data_page_version=f'{version}.0', row_group_size=113,
                               data_page_size=128, write_batch_size=16)
                target = source.with_stem(source.stem + '-native')
                subprocess.run([str(writer), str(source), str(target), str(version), '6'], check=True)
                for path in (source, target):
                    result = inspect_full_table(path, reader, out / 'evidence')
                    if result['native']['status'] != 'exported':
                        raise AssertionError(result)
                    actual = parse_native(Path(result['native']['artifact']).read_text())
                    expected = _arrow_export(data)
                    if compare_tables(expected, actual)['status'] != 'pass':
                        raise AssertionError((path, expected, actual))
                    if result['oracles']['pyarrow']['status'] != 'pass':
                        raise AssertionError(result)
                    metadata = inspect_metadata_evidence(path)
                    unexpected_findings = [finding for finding in metadata['findings']
                                           if count or finding['disposition'] != 'unresolved']
                    if unexpected_findings:
                        raise AssertionError(unexpected_findings)
                    footer = pq.ParquetFile(path).metadata
                    for g in range(footer.num_row_groups):
                        for c in range(footer.num_columns):
                            if footer.row_group(g).column(c).compression != 'ZSTD':
                                raise AssertionError('Wrong codec')
                    duck = json.loads(Path(result['oracles']['duckdb']['artifact']).read_text())['table']
                    if duck['rows'] != actual['rows'] or any(
                            left['name'] != right['name'] or left['values'] != right['values']
                            for left, right in zip(duck['columns'], actual['columns'], strict=True)):
                        raise AssertionError('DuckDB complete values/nulls differ')
                    result['oracles']['duckdb']['value_comparison'] = 'pass'
                    record = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), result=result, metadata=metadata)
                    review_errors(record, data, version, dictionary, writer)
                    records.append(record)
                    (out / 'results.partial.json').write_text(json.dumps(records, indent=2) + '\n')
                    print(path.name, {name: value['status'] for name, value in result['oracles'].items()}, flush=True)
    summary = {engine: dict(collections.Counter(r['result']['oracles'][engine]['status'] for r in records))
               for engine in ('pyarrow', 'duckdb', 'fastparquet')}
    (out / 'results.json').write_text(json.dumps(dict(summary=summary, records=records), indent=2) + '\n')
    print(out)
    print(json.dumps(summary, indent=2))
    unexpected = [r for r in records if any(o['status'] not in ('pass', 'limitation') and not o.get('reviewed_limitation') for o in r['result']['oracles'].values())]
    if unexpected:
        raise AssertionError(f'{len(unexpected)} oracle errors require review; full evidence: {out}')


if __name__ == '__main__':
    main()
