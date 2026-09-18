"""Complete native table parity. Oracle limitations never count as passes."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
KINDS = {1: 'uint32', 2: 'int8', 3: 'uint8', 4: 'int16', 5: 'uint16',
         6: 'int32', 7: 'int64', 8: 'uint64', 9: 'float32', 10: 'float64',
         11: 'bool', 12: 'binary', 13: 'fixed_binary'}


def _hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _sources(root):
    paths = []
    for base in (root / 'src', root / '../NuMojo', root / '../mojo-snappy'):
        paths.extend(path for path in base.rglob('*.mojo')
                     if not any(part in {'.pixi', 'build', '.git'} for part in path.parts))
    paths.extend(root / relative for relative in (
        'pixi.lock', 'pixi.toml', 'tests/coverage/read_table.mojo',
        'tests/read_numeric.mojo',
        '.pixi/envs/default/lib/libz.so.1',
        '.pixi/envs/default/lib/libKGENCompilerRTShared.so',
        '.pixi/envs/default/lib/mojo/mojo_snappy.mojoc',
        '.pixi/envs/default/lib/mojo/std.mojoc'))
    return {str(path.resolve()): _hash(path) for path in sorted(paths)}


def _run(command, cwd=None):
    try:
        run = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=120)
        return dict(returncode=run.returncode, stdout=run.stdout, stderr=run.stderr,
                    status='completed' if run.returncode == 0 else 'error')
    except subprocess.TimeoutExpired as exc:
        def text(value):
            return value.decode('utf8', errors='replace') if isinstance(value, bytes) else value or ''
        return dict(returncode=None, stdout=text(exc.stdout), stderr=text(exc.stderr), status='timeout')
    except OSError as exc:
        return dict(returncode=None, stdout='', stderr=str(exc), status='error')


def build_reader(repo_root=ROOT, binary=None, source="tests/coverage/read_table.mojo"):
    root = Path(repo_root).resolve()
    binary = Path(binary or root / 'build/coverage-ledger/read-table').resolve()
    binary.parent.mkdir(parents=True, exist_ok=True)
    command = ['pixi', 'run', 'mojo', 'build', '-O3', '-I', 'src', '-I',
               '../NuMojo', source, '-o', str(binary)]
    before = _sources(root)
    compiler = root / '.pixi/envs/default/bin/mojo'
    version_command = ['pixi', 'run', 'mojo', '--version']
    version = _run(version_command, cwd=root)
    if version['status'] != 'completed':
        raise RuntimeError(f'Compiler version check failed: {version}')
    compiler_hash = _hash(compiler)
    run = _run(command, cwd=root)
    provenance = dict(command=command, cwd=str(root), **run, source_hashes=before,
                      compiler_version_command=version_command, compiler_version=version,
                      compiler_path=str(compiler), compiler_sha256=compiler_hash)
    if run['status'] == 'completed':
        provenance['binary_sha256'] = _hash(binary)
        if before != _sources(root) or compiler_hash != _hash(compiler):
            provenance['status'] = 'inputs_changed_during_build'
    output = binary.with_suffix('.build.json')
    output.write_text(json.dumps(provenance, indent=2) + '\n')
    if provenance['status'] != 'completed':
        raise RuntimeError(f'Build failed or inputs changed; see {output}')
    return provenance


def verify_reader(binary):
    provenance_path = Path(binary).with_suffix('.build.json')
    provenance = json.loads(provenance_path.read_text())
    if provenance.get('status') != 'completed':
        raise ValueError('Build provenance is not a successful verified build')
    if provenance['binary_sha256'] != _hash(binary):
        raise ValueError('Reader binary differs from build provenance')
    if provenance['source_hashes'] != _sources(Path(provenance['cwd'])):
        raise ValueError('Reader sources/dependencies differ from build provenance')
    if provenance['compiler_sha256'] != _hash(provenance['compiler_path']):
        raise ValueError('Compiler differs from build provenance')
    return dict(status='verified', artifact=str(provenance_path), sha256=_hash(provenance_path))


def parse_native(text):
    lines = iter(text.splitlines())
    rows, count = map(int, next(lines).split())
    columns = []
    for _ in range(count):
        name = bytes.fromhex(next(lines)).decode('utf8')
        kind, nullable, width = map(int, next(lines).split())
        values = []
        for _ in range(rows):
            value = next(lines)
            values.append(None if value == 'null' else value[1:] if kind in (12, 13) else int(value))
        columns.append(dict(name=name, type=KINDS[kind], nullable=bool(nullable),
                            fixed_width=width, values=values))
    if list(lines):
        raise ValueError('Trailing native export data')
    return dict(rows=rows, columns=columns)


def _arrow_export(table, nullable=None):
    import numpy as np
    import pyarrow as pa
    columns = []
    for i, field in enumerate(table.schema):
        dtype = field.type
        if pa.types.is_fixed_size_binary(dtype):
            kind, width = 'fixed_binary', dtype.byte_width
        elif pa.types.is_binary(dtype):
            kind, width = 'binary', 0
        elif pa.types.is_boolean(dtype):
            kind, width = 'bool', 0
        elif pa.types.is_integer(dtype):
            kind, width = str(dtype), 0
        elif pa.types.is_float32(dtype):
            kind, width = 'float32', 0
        elif pa.types.is_float64(dtype):
            kind, width = 'float64', 0
        else:
            raise ValueError(f'Unrepresentable oracle type: {dtype}')
        values = []
        for chunk in table.column(i).chunks:
            # NumPy exposes floating bits without converting through Python float.
            bits = None
            if kind.startswith('float'):
                bits = chunk.to_numpy(zero_copy_only=False).view('uint' + kind[5:])
            for row, scalar in enumerate(chunk):
                if not scalar.is_valid:
                    values.append(None)
                elif bits is not None:
                    values.append(int(bits[row]))
                else:
                    value = scalar.as_py()
                    values.append(value.hex() if isinstance(value, bytes) else int(value))
        columns.append(dict(name=field.name, type=kind, fixed_width=width,
                            nullable=field.nullable if nullable is None else nullable[i], values=values))
    return dict(rows=table.num_rows, columns=columns)


def _fastparquet_export(path, columns=None):
    import fastparquet
    import numpy as np
    import pandas as pd
    with open(path, 'rb') as stream:
        file = fastparquet.ParquetFile(stream)
        frame = file.to_pandas(columns=columns)
    columns, limitations = [], []
    for i, name in enumerate(frame.columns):
        series = frame.iloc[:, i]
        element = file.schema.schema_element(name)
        nullable = element.repetition_type == 1
        dtype = str(series.dtype).lower()
        width = 0
        if element.type in (6, 7):
            kind = 'fixed_binary' if element.type == 7 else 'binary'
            width = element.type_length or 0
        elif element.type == 0:
            kind = 'bool'
        else:
            kind = dtype
        if kind not in KINDS.values():
            limitations.append(f'{name}: pandas dtype {dtype} does not preserve native type')
        values = []
        bits = series.to_numpy().view('uint' + kind[5:]) if kind in ('float32', 'float64') else None
        for row, value in enumerate(series):
            if value is None or value is pd.NA:
                values.append(None)
            elif isinstance(value, (float, np.floating)):
                if math.isnan(value) and nullable:
                    limitations.append(f'{name}: pandas NaN cannot distinguish null from valid NaN')
                if kind in ('float32', 'float64'):
                    values.append(int(bits[row]))
                else:
                    values.append(None if math.isnan(value) else int(value))
            elif isinstance(value, bytes):
                if kind == 'fixed_binary' and len(value) != width:
                    limitations.append(f'{name}: fixed binary output loses declared width (for example trailing NUL bytes)')
                values.append(value.hex())
            else:
                values.append(int(value))
        columns.append(dict(name=name, type=kind, fixed_width=width, nullable=nullable, values=values))
    return dict(rows=len(frame), columns=columns), sorted(set(limitations))


def _oracle(engine, path):
    if engine == 'pyarrow':
        import pyarrow.parquet as pq
        return _arrow_export(pq.ParquetFile(path).read()), []
    if engine == 'duckdb':
        import duckdb
        with duckdb.connect() as connection:
            connection.execute('SET threads=1')
            connection.execute('SET preserve_insertion_order=true')
            table = connection.execute('SELECT * FROM read_parquet(?, hive_partitioning=false)', [path]).to_arrow_table()
            schema = connection.execute('SELECT name, repetition_type, type FROM parquet_schema(?)', [path]).fetchall()
            nullable = [row[1] == 'OPTIONAL' for row in schema if row[2] is not None]
        exported = _arrow_export(table, nullable)
        limitations = []
        # DuckDB's BLOB representation erases fixed binary width.
        if any(column['type'] == 'binary' for column in exported['columns']):
            with duckdb.connect() as connection:
                physical = connection.execute('SELECT type FROM parquet_schema(?)', [path]).fetchall()
            if any(row[0] == 'FIXED_LEN_BYTE_ARRAY' for row in physical):
                limitations.append('DuckDB BLOB output does not preserve fixed binary type/width')
        return exported, limitations
    return _fastparquet_export(path)


def compare_tables(native, oracle):
    if native == oracle:
        return {'status': 'pass'}
    if native['rows'] != oracle['rows']:
        return {'status': 'mismatch', 'reason': 'row count'}
    if len(native['columns']) != len(oracle['columns']):
        return {'status': 'mismatch', 'reason': 'column count'}
    for i, (expected, actual) in enumerate(zip(native['columns'], oracle['columns'])):
        for key in ('name', 'type', 'nullable', 'fixed_width', 'values'):
            if expected[key] != actual[key]:
                return {'status': 'mismatch', 'column': i, 'reason': key}
    return {'status': 'mismatch', 'reason': 'unknown table difference'}


def _write_artifacts(prefix, run):
    result = {}
    for stream in ('stdout', 'stderr'):
        path = Path(str(prefix) + '.' + stream + '.txt')
        path.write_text(run[stream])
        result[stream + '_artifact'] = str(path)
        result[stream + '_sha256'] = _hash(path)
    return result


def inspect_full_table(path, binary, output_dir):
    path, binary, output = Path(path).resolve(), Path(binary).resolve(), Path(output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    identity = hashlib.sha256(str(path).encode()).hexdigest()[:16]
    prefix = output / (path.name + '-' + identity)
    command = [str(binary), str(path)]
    result = {'scope': 'complete_table', 'native': {'status': 'error', 'command': command},
              'oracles': {engine: {'status': 'not_exercised'} for engine in ('pyarrow', 'duckdb', 'fastparquet')}}
    try:
        result['build_provenance'] = verify_reader(binary)
    except (OSError, ValueError, KeyError) as exc:
        result['native'].update(status='provenance_error', error=str(exc))
        return result
    run = _run(command)
    result['native'].update(returncode=run['returncode'], **_write_artifacts(str(prefix) + '.native', run))
    result['native']['artifact'] = result['native']['stdout_artifact']
    result['native']['artifact_sha256'] = result['native']['stdout_sha256']
    if run['status'] != 'completed':
        result['native'].update(status=run['status'], error=(run['stdout'] + '\n' + run['stderr']).strip())
        return result
    try:
        native = parse_native(run['stdout'])
    except Exception as exc:
        result['native']['error'] = f'Export parse error: {exc}; {(run["stdout"] + run["stderr"]).strip()}'
        return result
    result['native'].update(status='exported', rows=native['rows'], columns=len(native['columns']))
    for engine in result['oracles']:
        artifact = Path(str(prefix) + f'.{engine}.json')
        artifact.unlink(missing_ok=True)
        oracle_command = [str(ROOT / 'build/oracle-uv/bin/python'), str(Path(__file__).resolve()), '--oracle', engine, str(path), str(artifact)]
        run = _run(oracle_command)
        entry = {'command': oracle_command, 'returncode': run['returncode'],
                 **_write_artifacts(str(prefix) + '.' + engine, run)}
        if artifact.exists():
            entry.update(artifact=str(artifact), artifact_sha256=_hash(artifact))
        if run['status'] != 'completed':
            entry.update(status=run['status'], error=(run['stdout'] + '\n' + run['stderr']).strip())
        else:
            try:
                payload = json.loads(artifact.read_text())
                entry['version'] = payload['version']
                entry['comparison_result'] = compare_tables(native, payload['table'])
                entry.update(entry['comparison_result'])
                if payload['limitations']:
                    entry.update(status='limitation', limitations=payload['limitations'])
            except (OSError, ValueError, KeyError) as exc:
                entry.update(status='error', error=f'Oracle artifact parse failed: {exc}')
        result['oracles'][engine] = entry
    return result


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == '--build':
        print(json.dumps(build_reader(), indent=2))
    elif len(sys.argv) == 5 and sys.argv[1] == '--oracle':
        from importlib.metadata import version
        table, limitations = _oracle(sys.argv[2], sys.argv[3])
        Path(sys.argv[4]).write_text(json.dumps(dict(table=table, limitations=limitations,
                                                   version=version(sys.argv[2]))))
    else:
        raise SystemExit('Use --build, inspect_full_table(), or --oracle ENGINE PATH OUTPUT')
