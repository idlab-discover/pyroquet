"""Run paired PLAIN/delta cohorts through the existing interference exclusions.

Uses the large-file runner's unchanged timing/monitoring loop. Only its manifest,
output root and candidate input path are substituted. Both encodings use the same
binary, flags and lifecycle; correctness is performed separately before timing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shape', choices=('flat', 'nested'), required=True)
    ap.add_argument('--rounds', type=int, default=6)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    base = ROOT / 'build/nested-performance'
    evidence = json.loads((base / 'manifest.json').read_text())
    pair = [f for f in evidence['fixtures'] if f['shape'] == a.shape]
    plain = next(f for f in pair if f['writer_options']['column_encoding'] == 'PLAIN')
    delta = next(f for f in pair if f['writer_options']['column_encoding'] == 'DELTA_BINARY_PACKED')
    for f in pair:
        with open(f['path'], 'rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == f['sha256']
        assert all(p['value_encoding'] == (0 if f is plain else 5) for p in f['pages'])
    cohort = base / ('timing-manifest-' + a.shape)
    cohort.mkdir(exist_ok=True)
    case = dict(case=a.shape, path=plain['path'], candidate_path=delta['path'],
                file_sha256=plain['sha256'], candidate_sha256=delta['sha256'],
                selected_names=['x'] if a.shape == 'flat' else [],
                output_bytes=plain['retained_bytes'], max_output_bytes=1 << 30)
    (cohort / 'manifest.json').write_text(json.dumps({'cases':[case]}, indent=2))
    binary = ROOT / ('build/nested-load' if a.shape == 'nested' else 'build/nested-flat-candidate/load')
    source = (ROOT / 'tests/large_files/run.py').read_text()
    source = source.replace("P=Path('benchmarks/large-files'); B=Path('build/large-files')",
                            f'P=Path({str(cohort)!r}); B=Path({str(base)!r})')
    old = "c['path'],str(c['max_output_bytes'])"
    assert source.count(old) == 1
    source = source.replace(old, "(c['candidate_path'] if engine=='candidate' else c['path']),str(c['max_output_bytes'])")
    runner = base / ('paired-runner-' + a.shape + '.py')
    runner.write_text(source)
    command = [sys.executable, str(runner), '--rounds', str(a.rounds), '--out', a.out,
               '--engines', 'pyroquet', '--binary', str(binary), '--candidate', str(binary)]
    print('PLAIN=pyroquet; DELTA_BINARY_PACKED=candidate; same executable', flush=True)
    raise SystemExit(subprocess.call(command, cwd=ROOT))

if __name__ == '__main__':
    main()
