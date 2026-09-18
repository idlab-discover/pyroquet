"""Public GZIP writer parity and independent page-stream validation.

Generate inputs with gzip_fixture_oracle.py; pass compiled roundtrip_mixed.mojo
and current coverage/read_table.mojo executables. No oracle runs in the library.
"""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import subprocess
import sys
import zlib

import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).resolve().parent / 'coverage'))
from full_table import _oracle, compare_tables, parse_native, verify_reader
from metadata_evidence import inspect_metadata_evidence

OUT = Path('build/gzip/writes')


def inspect_wire(path, mixed):
    raw = path.read_bytes()
    footer = pq.ParquetFile(path).metadata
    evidence = inspect_metadata_evidence(path)
    assert not evidence['findings'], evidence['findings']
    counts = Counter()
    for group_index, group in enumerate(evidence['row_groups']):
        for index, column in enumerate(group['columns']):
            codec = index % 3 if mixed else 2
            expected = ('UNCOMPRESSED', 'SNAPPY', 'GZIP')[codec]
            assert footer.row_group(group_index).column(index).compression == expected
            scan = column['page_scan']
            assert scan['column_uncompressed_matches_pages']
            assert scan['column_values_match_pages']
            for page in scan['page_records']:
                assert page['type'] in (0, 3), page
                detail = page.get('data_page_header', page.get('data_page_header_v2'))
                assert detail['encoding'] == 0
                begin = page['offset'] + page['header_bytes']
                stored = raw[begin:begin + page['compressed_page_size']]
                decoded_size = page['uncompressed_page_size']
                compressed = codec != 0
                if page['type'] == 3:
                    prefix = detail['definition_levels_byte_length'] + detail['repetition_levels_byte_length']
                    assert prefix <= len(stored) and prefix <= decoded_size
                    stored = stored[prefix:]
                    decoded_size -= prefix
                    compressed = compressed and detail['is_compressed'] is not False
                if codec == 2 and compressed:
                    decoder = zlib.decompressobj(wbits=31)
                    decoded = decoder.decompress(stored)
                    decoded += decoder.flush()
                    assert decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
                    assert len(decoded) == decoded_size
                    counts['gzip_single_member_checked'] += 1
                elif codec == 2:
                    assert len(stored) == decoded_size
                    counts['gzip_v2_raw_fallback'] += 1
    return dict(counts=counts, metadata=evidence)


def run(driver, reader):
    OUT.mkdir(parents=True, exist_ok=True)
    provenance = verify_reader(reader)
    identity = dict(reader=provenance, driver=str(driver),
                    driver_sha256=hashlib.sha256(driver.read_bytes()).hexdigest(),
                    oracle_versions={name: version(name) for name in ('pyarrow', 'duckdb', 'fastparquet')})
    manifest = json.loads(Path('build/gzip/manifest.json').read_text())
    results = []
    for fixture in manifest['fixtures']:
        source = Path(fixture['path'])
        assert hashlib.sha256(source.read_bytes()).hexdigest() == fixture['sha256']
        page_version = source.stem[1]
        for mixed in (False, True):
            path = OUT / (source.stem + ('_mixed' if mixed else '_gzip') + '.parquet')
            path.unlink(missing_ok=True)
            command = [str(driver), str(source), str(path), page_version, '-2' if mixed else '2']
            written = subprocess.run(command, capture_output=True, text=True)
            assert written.returncode == 0, (command, written.stdout, written.stderr)
            native = subprocess.run([str(reader), str(path)], capture_output=True, text=True)
            assert native.returncode == 0, (path, native.stdout, native.stderr)
            exported = parse_native(native.stdout)
            comparison = compare_tables(fixture['expected'], exported)
            assert comparison['status'] == 'pass', (path, comparison)
            entry = dict(path=str(path), command=command,
                         sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                         producer_input=comparison, wire=inspect_wire(path, mixed), oracles={})
            for engine in ('pyarrow', 'duckdb', 'fastparquet'):
                try:
                    oracle, limitations = _oracle(engine, str(path))
                    result = compare_tables(exported, oracle)
                    if limitations:
                        result = dict(status='limitation', limitations=limitations, comparison_result=result)
                    entry['oracles'][engine] = result
                except Exception as error:
                    entry['oracles'][engine] = dict(status='error', error=str(error))
            assert entry['oracles']['pyarrow']['status'] == 'pass', entry
            results.append(entry)
            print(path.name, {k: v['status'] for k, v in entry['oracles'].items()}, flush=True)
    assert verify_reader(reader) == provenance
    total = Counter()
    for entry in results:
        total.update(entry['wire']['counts'])
    assert total['gzip_single_member_checked'] > 0 and total['gzip_v2_raw_fallback'] > 0
    summary = {engine: dict(Counter(r['oracles'][engine]['status'] for r in results))
               for engine in ('pyarrow', 'duckdb', 'fastparquet')}
    (OUT / 'results.json').write_text(json.dumps(dict(identity=identity, summary=summary, page_totals=total, cases=results), indent=2))
    print(json.dumps(dict(summary=summary, page_totals=total), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--reader', type=Path, required=True)
    args = parser.parse_args()
    run(args.driver.resolve(), args.reader.resolve())
