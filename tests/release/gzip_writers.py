"""Fresh GZIP writer outputs: independent wire checks and central full parity."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / 'tests/coverage'))
import gzip_fixture_oracle
from check_gzip_writes import inspect_wire
from full_table import build_reader, verify_reader, parse_native, compare_tables
from parity import export_native, compare_export


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def match_review(path, sha, result, catalog):
    known = next((r for r in catalog if r['path'] == Path(path).name and r['sha256'] == sha
                  and r['version'] == importlib.metadata.version('fastparquet')), None)
    if (known is not None
            and result['unexpected'] == [dict(engine='fastparquet', error=known['error'])]
            and result['engines']['pyarrow']['dimensions'].get('values') == 'pass'
            and result['engines']['duckdb']['dimensions'].get('values') == 'pass'):
        return known
    return None


def run(binary, out):
    out = Path(out).resolve(); out.mkdir(parents=True, exist_ok=False)
    binary = Path(binary).resolve()
    report = dict(status='running', fixtures=[], limitations=[], unexpected=[],
                  binary=dict(path=str(binary), sha256=digest(binary)))
    def save():
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    save()
    driver, reader = out / 'roundtrip', out / 'read-table'
    build_reader(binary=driver, source='tests/roundtrip_mixed.mojo')
    build_reader(binary=reader)
    report['provenance'] = dict(driver=verify_reader(driver), reader=verify_reader(reader))
    gzip_fixture_oracle.OUT = out / 'inputs'
    gzip_fixture_oracle.generate()
    manifest = json.loads((gzip_fixture_oracle.OUT / 'manifest.json').read_text())
    if len(manifest['fixtures']) != 16:
        raise ValueError('Expected all 16 independent GZIP inputs')
    catalog_path = Path(__file__).with_name('gzip_writer_limitations.json')
    catalog = json.loads(catalog_path.read_text())['fixtures'] if catalog_path.exists() else []
    total = Counter()
    for fixture in manifest['fixtures']:
        source = Path(fixture['path'])
        if digest(source) != fixture['sha256']:
            raise ValueError('GZIP input bytes changed')
        version = int(source.stem[1])
        for mixed in (False, True):
            path = out / (source.stem + ('_mixed' if mixed else '_gzip') + '.parquet')
            command = [str(driver), str(source), str(path), str(version), '-2' if mixed else '2']
            subprocess.run(command, check=True, capture_output=True, text=True)
            native = subprocess.run([str(reader), str(path)], check=True, capture_output=True, text=True)
            exported = parse_native(native.stdout)
            producer = compare_tables(fixture['expected'], exported)
            if producer['status'] != 'pass':
                raise ValueError(dict(path=str(path), producer=producer))
            wire = inspect_wire(path, mixed)
            total.update(wire['counts'])
            directory = out / (path.stem + '-export')
            export_native(path, binary, directory, 256 * 1024**2)
            result = compare_export(path, directory)
            sha = digest(path)
            known = match_review(path, sha, result, catalog)
            if known is not None:
                required = [dict(engine='fastparquet', error=known['error'])]
                control = out / (path.stem + '-uncompressed-control.parquet')
                subprocess.run([str(driver), str(source), str(control), str(version), '0'], check=True)
                if digest(control) != known['control_sha256']:
                    raise ValueError('Reviewed GZIP control bytes changed')
                control_native = subprocess.run([str(reader), str(control)], check=True, capture_output=True, text=True)
                if compare_tables(exported, parse_native(control_native.stdout))['status'] != 'pass':
                    raise ValueError('Compression-only control changes values/types/nulls')
                control_out = out / (path.stem + '-control-export')
                export_native(control, binary, control_out, 256 * 1024**2)
                control_result = compare_export(control, control_out)
                (control_out / 'report.json').write_text(json.dumps(control_result, indent=2) + '\n')
                if control_result['unexpected'] != required:
                    raise ValueError('Reviewed GZIP uncompressed control no longer reproduces exact error')
                engine = result['engines']['fastparquet']
                engine['observed_failure'] = dict(error=engine['error'], fixture_sha256=sha)
                engine['status'] = 'reviewed_limitation'
                engine['limitations'].append(known['reason'])
                engine['dimensions'].update(values='not established: reviewed reader error', nulls='not established', order='not established')
                result['limitations'].append(dict(engine='fastparquet', reason=known['reason'], evidence=known, control=str(control)))
                result['unexpected'] = []
                result['status'] = 'with_limitations'
            (directory / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
            report['fixtures'].append(dict(path=str(path), sha256=sha, command=command,
                                           producer_input=producer, wire=wire, result=result))
            report['limitations'].extend(result['limitations'])
            report['unexpected'].extend(dict(path=str(path), **error) for error in result['unexpected'])
            save()
            print(path.name, result['status'], flush=True)
    if len(report['fixtures']) != 32 or total['gzip_single_member_checked'] == 0 or total['gzip_v2_raw_fallback'] == 0:
        raise ValueError('Incomplete GZIP writer matrix or compression/fallback wire checks')
    if report['provenance'] != dict(driver=verify_reader(driver), reader=verify_reader(reader)) or digest(binary) != report['binary']['sha256']:
        raise ValueError('GZIP writer verification inputs changed')
    report['page_totals'] = dict(total)
    report['status'] = 'failed' if report['unexpected'] else 'with_limitations' if report['limitations'] else 'pass'
    save()
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    new_output = not args.out.exists()
    try:
        result = run(args.binary, args.out)
    except Exception as error:
        report_path = args.out / 'report.json'
        if new_output and report_path.exists():
            partial = json.loads(report_path.read_text())
            partial['status'] = 'failed'
            partial['unexpected'].append(dict(error=str(error)))
            report_path.write_text(json.dumps(partial, indent=2) + '\n')
        raise
    print(json.dumps(dict(status=result['status'], fixtures=len(result['fixtures']), unexpected=result['unexpected'])))
    raise SystemExit(result['status'] == 'failed')
