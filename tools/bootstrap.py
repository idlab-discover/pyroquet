#!/usr/bin/env python3
"""Bootstrap the pinned Linux x86-64 development environment without replacing it.

Requires Python 3, Pixi 0.80.0 and uv 0.12.10. Mojo dependencies come from the
locked Pixi environment. An existing oracle environment is verified, never reinstalled.
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


def run(command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


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
    parser.add_argument('--pixi', default='pixi', help='Path to Pixi 0.80.0')
    parser.add_argument('--uv', default='uv', help='Path to uv 0.12.10')
    args = parser.parse_args()
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        parser.error('The release environment requires Linux x86-64')
    report = dict(pixi=tool_version(args.pixi, PIXI_VERSION), uv=tool_version(args.uv, UV_VERSION))
    run([args.pixi, 'install', '--locked'], cwd=ROOT)
    report['oracle'] = prepare_oracle(ROOT, args.uv)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
