"""Collect serialized function counts using already-built audit executables.

Run from the repository root. Requires the large-file manifest and instrument.py
output. Refuses to reuse an evidence directory. No measurements are benchmarks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instrumented', type=Path, required=True)
    parser.add_argument('--reader', type=Path, required=True)
    parser.add_argument('--writer', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cases', nargs='+')
    parser.add_argument('--supplemental', type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    functions = json.loads((args.instrumented / 'functions.json').read_text())
    for function in functions:
        assert sha(function['file']) == function['source_sha256'], 'Production source changed since instrumentation'
    manifest = Path('benchmarks/large-files/manifest.json')
    cases = json.loads(manifest.read_text())['cases']
    if args.cases:
        assert set(args.cases) <= {case['case'] for case in cases}, 'Unknown case'
        cases = [case for case in cases if case['case'] in args.cases]
    binaries = [args.reader, args.writer] + ([args.supplemental] if args.supplemental else [])
    identity = dict(manifest_sha256=sha(manifest),
                    functions_sha256=sha(args.instrumented / 'functions.json'),
                    binaries={str(path): sha(path) for path in binaries},
                    source_revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                    source_status=subprocess.check_output(['git', 'status', '--short'], text=True),
                    compiler=subprocess.check_output(['pixi', 'run', 'mojo', '--version'], text=True),
                    pixi_lock_sha256=sha('pixi.lock'),
                    instrumented_files={str(path.relative_to(args.instrumented)): sha(path)
                                        for path in args.instrumented.rglob('*') if path.is_file()},
                    tools={str(path): sha(path) for path in Path('tests/dead_code').glob('*') if path.is_file()})
    (args.out / 'identity.json').write_text(json.dumps(identity, indent=2))
    results = []
    hashes = {}

    def execute(label, binary, cli, case=None):
        counts = (args.out / (label + '.counts')).resolve()
        env = os.environ.copy()
        env['PYROQUET_AUDIT_COUNTS'] = str(counts)
        cmd = ['pixi', 'run', str(binary.resolve()), *cli]
        start = time.monotonic()
        with (args.out / (label + '.log')).open('w') as log:
            result = subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
        item = dict(label=label, command=cmd, returncode=result.returncode,
                    elapsed_seconds=time.monotonic() - start)
        if case:
            item.update(case=case['case'], file_sha256=hashes[case['path']],
                        rows=case['rows'], selected_names=case['selected_names'],
                        whole_file_bytes=Path(case['path']).stat().st_size,
                        selected_compressed_bytes=case.get('selected_compressed_bytes'))
        results.append(item)
        (args.out / 'runs.json').write_text(json.dumps(results, indent=2))
        if result.returncode:
            raise RuntimeError(f'{label} failed; see its log')
        values = [tuple(map(int, line.split())) for line in counts.read_text().splitlines()]
        assert [i for i, _ in values] == list(range(len(functions))), 'Incomplete counter file'
        assert any(value > 0 for _, value in values), 'No function entries recorded'
        item['counts'] = dict(values)
        print(label, 'passed', round(item['elapsed_seconds'], 2), flush=True)

    for case in cases:
        path = case['path']
        if path not in hashes:
            hashes[path] = sha(path)
        assert hashes[path] == case['file_sha256'], f'Changed fixture: {path}'
        label = case['case'].replace('/', '-').replace(' ', '-')
        execute(label + '.read', args.reader,
                [path, str(case['max_output_bytes']), '0', '-', *case['selected_names']], case)
        if case['case'].endswith('-wide') or case['case'] == 'Repo dictionary/nulls':
            output = (args.out / (label + '.parquet')).resolve()
            # Large originals: Snappy V1; nullable control: Snappy V2.
            version = '2' if case['case'] == 'Repo dictionary/nulls' else '1'
            execute(label + '.roundtrip', args.writer,
                    [path, str(case['max_output_bytes']), str(output), version, '1', *case['selected_names']], case)
    if args.supplemental:
        execute('supplemental', args.supplemental, [])
    (args.out / 'runs.json').write_text(json.dumps(results, indent=2))
    for function in functions:
        function['observed'] = {run['label']: run['counts'][function['id']]
                                for run in results if run['counts'][function['id']]}
    (args.out / 'coverage.json').write_text(json.dumps(functions, indent=2))
    print('Observed', sum(bool(f['observed']) for f in functions), 'of',
          sum(f['instrumented'] for f in functions), 'instrumented definitions')


if __name__ == '__main__':
    main()
