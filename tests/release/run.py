"""Portable, fail-closed release qualification; development tooling only.

Each invocation retains commands, output, resource usage and source identity in a
new ignored evidence directory. Large qualification requires ordinary checks for
exactly the same source/environment identity. Limitations are never passes.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / 'build/oracle-uv/bin/python'
PINNED = {'NuMojo': '515fb2856f0ecf3d2740a34d958fe168183e1129',
          'mojo-snappy': 'ad02f439892d7b7813677d94f8e0951be63d0041'}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def identity():
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('The 0.1.0 qualification target is Linux x86-64')
    sources = {}
    for name in git('ls-files').splitlines():
        path = ROOT / name
        if path.is_file():
            sources[name] = digest(path)
    deps = {}
    for name, revision in PINNED.items():
        path = ROOT.parent / name
        actual = git('rev-parse', 'HEAD', cwd=path)
        dirty = git('status', '--porcelain', cwd=path)
        if actual != revision or dirty:
            raise RuntimeError(f'{name}: expected clean revision {revision}; got {actual}, {dirty!r}')
        deps[name] = {'revision': actual, 'files': {
            n: digest(path / n) for n in git('ls-files', cwd=path).splitlines()
            if (path / n).is_file()}}
    versions = {}
    for line in (ROOT / 'tests/oracle-requirements.txt').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        name, expected = line.split('==')
        actual = importlib.metadata.version(name)
        if actual != expected:
            raise RuntimeError(f'Oracle version mismatch: {name} {actual} != {expected}')
        versions[name] = actual
    prefix = ROOT / '.pixi/envs/default'
    runtime = {name: digest(prefix / name) for name in (
        'bin/mojo', 'lib/mojo/std.mojoc', 'lib/mojo/mojo_snappy.mojoc',
        'lib/libKGENCompilerRTShared.so', 'lib/libz.so.1', 'lib/libzstd.so.1',
        'lib/libMSupportGlobals.so', 'lib/libAsyncRTRuntimeGlobals.so',
        'lib/libstdc++.so.6', 'lib/libgcc_s.so.1')}
    dynamic = subprocess.check_output(['ldd', str(prefix / 'lib/libKGENCompilerRTShared.so')], text=True)
    for line in dynamic.splitlines():
        parts = line.split('=>', 1)[-1].strip().split()
        if parts and parts[0].startswith('/'):
            runtime[parts[0]] = digest(parts[0])
    return {'commit': git('rev-parse', 'HEAD'),
            'dirty': git('status', '--porcelain'), 'sources': sources,
            'dependencies': deps, 'runtime': runtime, 'oracles': versions,
            'python': sys.version, 'platform': platform.platform(),
            'compiler': subprocess.check_output(['pixi', 'run', 'mojo', '--version'], cwd=ROOT, text=True).strip()}


def validate_parity(result):
    if result.get('status') not in ('pass', 'with_limitations'):
        raise RuntimeError('Parity report lacks a successful terminal state')
    if result.get('unexpected') != []:
        raise RuntimeError('Parity report lacks an empty unexpected-outcome list')
    engines = result.get('engines', {})
    if set(engines) != {'pyarrow', 'duckdb', 'fastparquet'}:
        raise RuntimeError('Parity report does not cover all three independent readers')
    for name, entry in engines.items():
        if entry.get('status') not in ('pass', 'with_limitations', 'reviewed_limitation'):
            raise RuntimeError('Unreviewed oracle status: ' + name)
        if not isinstance(entry.get('dimensions'), dict):
            raise RuntimeError('Oracle report lacks comparison dimensions: ' + name)
        if entry['status'] != 'pass' and not entry.get('limitations'):
            raise RuntimeError('Oracle nonpass lacks explicit limitations: ' + name)


def verify_artifacts(gate):
    for group in ('binaries', 'packages', 'evidence'):
        for path, sha in gate.report.get(group, {}).items():
            if digest(ROOT / path) != sha:
                raise RuntimeError('A frozen artifact changed: ' + path)
    fixture = gate.report.get('fixture_manifest')
    if fixture:
        manifest_path = Path(fixture['path'])
        if digest(manifest_path) != fixture['sha256']:
            raise RuntimeError('Fixture manifest changed')
        for record in json.loads(manifest_path.read_text())['files']:
            path = manifest_path.parent / record['path']
            if path.stat().st_size != record['bytes'] or digest(path) != record['sha256']:
                raise RuntimeError('A frozen fixture changed: ' + str(path))


class Gate:
    def __init__(self, out, candidate):
        self.out = out
        self.report = {'status': 'running', 'candidate': candidate,
                       'started_utc': datetime.now(timezone.utc).isoformat(),
                       'steps': [], 'limitations': [], 'unexpected': []}
        self.save()

    def save(self):
        (self.out / 'report.json').write_text(json.dumps(self.report, indent=2) + '\n')

    def run(self, name, command, *, env=None):
        index = len(self.report['steps'])
        prefix = self.out / f'{index:03d}-{name}'
        usage = prefix.with_suffix('.usage.json')
        actual = list(map(str, command))
        print(f'[{index:03d}] {name}', flush=True)
        record = {'name': name, 'command': list(map(str, command)), 'cwd': str(ROOT),
                  'stdout': str(prefix.with_suffix('.stdout')), 'stderr': str(prefix.with_suffix('.stderr'))}
        self.report['steps'].append(record)
        self.save()
        with open(record['stdout'], 'wb') as stdout, open(record['stderr'], 'wb') as stderr:
            started = time.perf_counter()
            process = subprocess.Popen(actual, cwd=ROOT, env=env, stdout=stdout, stderr=stderr)
            _, status, resources = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
            elapsed = time.perf_counter() - started
        record['returncode'] = process.returncode
        record['resources'] = {'peak_rss_kib': resources.ru_maxrss,
                               'elapsed_seconds': elapsed,
                               'user_seconds': resources.ru_utime,
                               'system_seconds': resources.ru_stime}
        usage.write_text(json.dumps(record['resources'], indent=2) + '\n')
        record['resource_artifact'] = str(usage)
        record['stdout_sha256'] = digest(record['stdout'])
        record['stderr_sha256'] = digest(record['stderr'])
        self.save()
        if process.returncode:
            raise RuntimeError(f'{name} exited {process.returncode}; see {record["stderr"]}')
        return record

    def build(self, source, name, assertion='all'):
        target = self.out / 'bin' / name
        target.parent.mkdir(exist_ok=True)
        self.run('build-' + name, ['pixi', 'run', 'mojo', 'build', '-O3', '-D',
                                  'ASSERT=' + assertion, '-I', 'src', '-I', '../NuMojo', source, '-o', target])
        self.report.setdefault('binaries', {})[str(target)] = digest(target)
        self.save()
        return target


def native_checks(gate):
    for name in ('nested', 'string', 'enum', 'gzip', 'float16'):
        gate.run('generate-' + name, [PYTHON, f'tests/{name}_fixture_oracle.py', '--generate'])
    for source in sorted((ROOT / 'tests').glob('test_*.mojo')):
        binary = gate.build(str(source.relative_to(ROOT)), source.stem)
        gate.run(source.stem, [binary])
    # The acceptance seams also run with language assertions removed.
    for name in ('numeric_mutation', 'boolean_column', 'float16', 'zstd',
                 'packed_validity', 'nullable_dictionary', 'dictionary_gather',
                 'snappy_pages', 'delta', 'publication', 'numeric_write', 'table_write'):
        binary = gate.build(f'tests/test_{name}.mojo', 'noassert-' + name, 'none')
        gate.run('noassert-' + name, [binary])
    for source in sorted((ROOT / 'tests').glob('check_*ownership.py')):
        gate.run(source.stem, [PYTHON, source])
    for script in ('check_test_failures', 'check_zlib_abi', 'check_gzip_failures',
                   'check_zstd', 'check_snappy_resolution'):
        gate.run(script, [PYTHON, f'tests/{script}.py'])
    gate.run('float16-oracles', [PYTHON, 'tests/float16_fixture_oracle.py', '--verify'])
    gate.run('coverage-regressions', [PYTHON, '-m', 'unittest', 'discover', '-s', 'tests/coverage', '-p', 'test_*.py'])
    for task, artifact in [('package', 'build/pyroquet.mojoc'), ('package-compact', 'build/compact_protocol.mojoc')]:
        gate.run(task, ['pixi', 'run', task])
        gate.report.setdefault('packages', {})[artifact] = digest(ROOT / artifact)


def fixtures_and_parity(gate, large, binary=None):
    directory = gate.out / 'fixtures'
    command = [PYTHON, 'tests/release/fixtures.py', '--out', directory]
    if large:
        command.append('--large')
    gate.run('generate-portable-fixtures', command)
    manifest_path = directory / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    gate.report['fixture_manifest'] = {'path': str(manifest_path), 'sha256': digest(manifest_path)}
    if binary is None:
        binary = gate.build('tests/release/export.mojo', 'release-export')
    else:
        gate.report.setdefault('binaries', {})[str(binary)] = digest(binary)
    if not large:
        gate.run('release-regressions', [PYTHON, '-m', 'unittest', 'discover', '-s', 'tests/release', '-p', 'test_*.py'],
                 env=dict(os.environ, PYROQUET_RELEASE_EXPORT=str(binary)))
    selected = [f for f in manifest['files'] if (f['category'] == 'large') == large]
    if large and (len(selected) < 2 or any(f['bytes'] <= 2**30 for f in selected)
                  or not {'flat', 'mixed'} <= {f.get('shape') for f in selected}):
        raise RuntimeError('Large gate requires two structurally different files exceeding 1 GiB on disk')
    gate.report['parity'] = []
    for i, fixture in enumerate(selected):
        path = directory / fixture['path']
        if digest(path) != fixture['sha256'] or path.stat().st_size != fixture['bytes']:
            raise RuntimeError('Fixture identity changed: ' + str(path))
        output = gate.out / 'parity' / str(i)
        budget = fixture['decoded_budget_bytes']
        gate.run(f'parity-{i}', [PYTHON, 'tests/release/parity.py', '--file', path,
                                '--binary', binary, '--out', output, '--budget', str(budget)])
        result_path = output / 'report.json'
        result = json.loads(result_path.read_text())
        validate_parity(result)
        gate.report.setdefault('evidence', {})[str(result_path)] = digest(result_path)
        gate.report['parity'].append({'fixture': fixture, 'report': str(result_path),
                                      'report_sha256': digest(result_path), 'result': result})
        gate.report['limitations'].extend(result.get('limitations', []))
        if result.get('unexpected') or result.get('status') == 'failed':
            raise RuntimeError('Unexpected parity failure: ' + str(result_path))
        if large:
            measurement = gate.run(f'complete-load-{i}', [binary, path, '-', str(budget), '5'])
            timings = [int(line.split()[1]) for line in Path(measurement['stdout']).read_text().splitlines()
                       if line.startswith('TIME ')]
            if len(timings) < 3:
                raise RuntimeError('Large measurement did not produce repeated complete-load samples')
            measurement['load_ns'] = timings
            measurement['minimum_ns'] = min(timings)
            measurement['maximum_ns'] = max(timings)
            gate.save()
    gate.report['exporter'] = str(binary)
    gate.save()
    return binary, selected, directory


def execution_audit(gate, binary, fixture, directory):
    # Trace actual dynamic loading on the tested native path, including lazy codecs.
    env = dict(os.environ, LD_DEBUG='libs', PYTHONHOME='/pyroquet-no-python',
               PYTHONPATH='/pyroquet-no-python')
    record = gate.run('native-loader-audit', [binary, directory / fixture['path'], '-',
                                            str(fixture['decoded_budget_bytes'])], env=env)
    loaded = Path(record['stderr']).read_text()
    if 'libpython' in loaded.lower():
        raise RuntimeError('Native execution unexpectedly loaded libpython')
    for tool in ('readelf', 'ldd'):
        args = [tool, '-d', binary] if tool == 'readelf' else [tool, binary]
        step = gate.run('native-' + tool, args)
        if 'libpython' in Path(step['stdout']).read_text().lower():
            raise RuntimeError('Native executable links Python')
    gate.report.setdefault('runtime_audits', []).append({'status': 'pass', 'fixture': fixture['path'], 'codec': fixture['options']['codec'],
        'scope': 'compiled exporter dependencies and actual fixture execution',
        'python_interop': 'NuMojo includes optional interop definitions; no Pyroquet execution uses them'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--large', action='store_true')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--development', action='store_true', help='Permit dirty source; result is not candidate qualification')
    parser.add_argument('--skip-native', action='store_true', help='Development only; cannot qualify a candidate')
    args = parser.parse_args()
    if args.skip_native and not args.development:
        parser.error('--skip-native requires --development')
    os.environ['LD_LIBRARY_PATH'] = str(ROOT / '.pixi/envs/default/lib')
    candidate = identity()
    if candidate['dirty'] and not args.development:
        raise RuntimeError('Commit the candidate before qualification (or use --development for nonqualifying checks)')
    base = ROOT / 'build/release'
    base.mkdir(parents=True, exist_ok=True)
    out = args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix='large-' if args.large else 'ordinary-', dir=base))
    out.mkdir(parents=True, exist_ok=True)
    if (out / 'report.json').exists():
        raise RuntimeError('Evidence output already contains a report; choose a fresh directory')
    gate = Gate(out, candidate)
    gate.report['mode'] = 'large' if args.large else 'ordinary'
    gate.report['development'] = args.development
    print('Evidence:', out, flush=True)
    try:
        frozen_exporter = None
        if args.large and not args.development:
            prior = json.loads((base / 'ordinary.json').read_text())
            ordinary = json.loads(Path(prior['report']).read_text())
            if ordinary['status'] != 'qualified_with_recorded_nonpasses' or ordinary['candidate'] != candidate:
                raise RuntimeError('Large checks require ordinary qualification of the identical frozen candidate')
            if digest(prior['report']) != prior['sha256']:
                raise RuntimeError('Ordinary qualification report changed')
            gate.report['ordinary_qualification'] = prior
            frozen_exporter = Path(ordinary['exporter'])
            if digest(frozen_exporter) != ordinary['binaries'][str(frozen_exporter)]:
                raise RuntimeError('Ordinary frozen exporter changed')
        if not args.large and not args.skip_native:
            native_checks(gate)
        binary, fixtures, directory = fixtures_and_parity(gate, args.large, frozen_exporter)
        if not args.large:
            gate.run('golden-corpus', [PYTHON, 'tests/release/corpus.py', '--binary', binary, '--out', out / 'corpus'])
            corpus = json.loads((out / 'corpus/report.json').read_text())
            if corpus.get('unexpected') != [] or corpus.get('status') not in ('pass', 'with_limitations'):
                raise RuntimeError('Unexpected golden corpus outcome')
            gate.report['corpus'] = corpus
            gate.report.setdefault('evidence', {})[str(out / 'corpus/report.json')] = digest(out / 'corpus/report.json')
            gate.report['limitations'].extend(corpus.get('limitations', []))
            # Audit each codec path with a nonempty fixture.
            for codec in (0, 1, 2, 6):
                choices = [f for f in fixtures if f.get('rows', 0) and f.get('options', {}).get('codec') == codec]
                if not choices:
                    raise RuntimeError(f'No runtime audit fixture for codec {codec}')
                execution_audit(gate, binary, choices[0], directory)
        if identity() != candidate:
            raise RuntimeError('Source, dependency, compiler or oracle identity changed during qualification')
        verify_artifacts(gate)
        gate.report['status'] = 'development_checks_completed' if args.development else 'qualified_with_recorded_nonpasses'
    except Exception as exc:
        gate.report['status'] = 'failed'
        gate.report['unexpected'].append(repr(exc))
        raise
    finally:
        gate.report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        gate.save()
    if not args.development:
        (base / ('large.json' if args.large else 'ordinary.json')).write_text(json.dumps(
            {'report': str(out / 'report.json'), 'sha256': digest(out / 'report.json')}, indent=2) + '\n')
    print(gate.report['status'], out / 'report.json', flush=True)


if __name__ == '__main__':
    main()
