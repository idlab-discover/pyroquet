#!/usr/bin/env python3
"""Bootstrap the pinned Linux x86-64 development environment without replacing it.

Requires Git and Python 3. Full setup also requires Pixi 0.80.0 and uv 0.12.10.
--dependencies-only prepares sibling checkouts before Pixi evaluates local paths.
Existing checkouts and oracle environments are verified, never reset/reinstalled.
"""
from __future__ import annotations

import argparse
import json
import platform
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PYTHON_VERSION = '3.12.13'
PIXI_VERSION = '0.80.0'
UV_VERSION = '0.12.10'
DEPENDENCIES = {
    'NuMojo': ('https://github.com/Mojo-Numerics-and-Algorithms-group/NuMojo.git',
               '515fb2856f0ecf3d2740a34d958fe168183e1129'),
    'mojo-snappy': ('https://github.com/idlab-discover/mojo-snappy.git',
                    'ad02f439892d7b7813677d94f8e0951be63d0041'),
}


def run(command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], text=True).strip()


def verify_checkout(path, revision):
    if Path(git(path, 'rev-parse', '--show-toplevel')).resolve() != path.resolve():
        raise RuntimeError(f'{path} is not a standalone dependency checkout; left unchanged')
    actual = git(path, 'rev-parse', 'HEAD')
    if actual != revision:
        raise RuntimeError(f'{path}: expected {revision}, found {actual}; left unchanged')
    if git(path, 'status', '--porcelain', '--untracked-files=no'):
        raise RuntimeError(f'{path}: tracked modifications present; left unchanged')
    return dict(path=str(path), revision=actual,
                untracked=git(path, 'ls-files', '--others', '--exclude-standard'))


def prepare_dependency(path, remote, revision):
    path = Path(path)
    if not path.exists():
        # Exclusive creation prevents a racing bootstrap from touching another
        # process's checkout. Failed acquisitions remain available for diagnosis.
        path.mkdir(parents=False)
        run(['git', 'init', '-q', path])
        run(['git', '-C', path, 'remote', 'add', 'origin', remote])
        run(['git', '-C', path, 'fetch', '--depth', '1', 'origin', revision])
        run(['git', '-C', path, 'checkout', '--detach', 'FETCH_HEAD'])
    return verify_checkout(path, revision)


def requirements(path):
    expected = {}
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        name, version = line.split('==')
        if not name or not version or name in expected:
            raise ValueError(f'Invalid exact oracle requirement: {line}')
        expected[name] = version
    return expected


def verify_oracle(directory, expected):
    python = directory / 'bin/python'
    if not python.is_file():
        raise RuntimeError(f'{directory}: existing path is not an oracle environment; left unchanged')
    program = '''import importlib.metadata, json, platform, sys
names=json.loads(sys.argv[1])
print(json.dumps(dict(python=platform.python_version(), packages={n:importlib.metadata.version(n) for n in names})))'''
    actual = json.loads(subprocess.check_output(
        [str(python), '-I', '-c', program, json.dumps(list(expected))], text=True))
    if actual['python'] != PYTHON_VERSION or actual['packages'] != expected:
        raise RuntimeError(f'{directory}: oracle versions differ from pins; left unchanged: {actual}')
    return actual


def prepare_oracle(root, uv):
    directory = root / 'build/oracle-uv'
    requirement_file = root / 'tests/oracle-requirements.txt'
    expected = requirements(requirement_file)
    if directory.exists():
        return verify_oracle(directory, expected)
    directory.parent.mkdir(parents=True, exist_ok=True)
    directory.mkdir()  # reserve exclusively; never clear or overwrite a venv
    run([uv, 'python', 'install', PYTHON_VERSION])
    run([uv, 'venv', '--no-project', '--allow-existing', '--python', PYTHON_VERSION, directory])
    run([uv, 'pip', 'install', '--python', directory / 'bin/python', '-r', requirement_file])
    return verify_oracle(directory, expected)


def tool_version(tool, expected):
    actual = subprocess.check_output([tool, '--version'], text=True).strip()
    if len(actual.split()) < 2 or actual.split()[1] != expected:
        raise RuntimeError(f'{tool}: expected version {expected}, got {actual}')
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dependencies-only', action='store_true')
    parser.add_argument('--pixi', default='pixi', help='Path to Pixi 0.80.0')
    parser.add_argument('--uv', default='uv', help='Path to uv 0.12.10')
    args = parser.parse_args()
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        parser.error('The release environment requires Linux x86-64')
    report = dict(dependencies={})
    for name, (remote, revision) in DEPENDENCIES.items():
        report['dependencies'][name] = prepare_dependency(ROOT.parent / name, remote, revision)
    if not args.dependencies_only:
        report['pixi'] = tool_version(args.pixi, PIXI_VERSION)
        report['uv'] = tool_version(args.uv, UV_VERSION)
        run([args.pixi, 'install', '--locked'], cwd=ROOT)
        report['oracle'] = prepare_oracle(ROOT, args.uv)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
