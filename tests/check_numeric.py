"""Ten-dtype PLAIN loading: independent readers, bit identity and strict typing."""
from pathlib import Path
import json
import math
import struct
import subprocess
import duckdb
import pyarrow as pa
import pyarrow.parquet as pq
from check_pages import header_fields, thrift_bytes, T
from check_metadata import fields, parts, put, encode

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/numeric-checks'
BINARY = ROOT / 'build/read-numeric'
TYPES = ['int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32',
         'int64', 'uint64', 'float32', 'float64']


def encoded(value, dtype):
    if value is None:
        return None
    if dtype.startswith('float'):
        return int.from_bytes(struct.pack('<f' if dtype == 'float32' else '<d', value), 'little')
    return int(value)


def probe(path, dtype, budget=None):
    args = [str(BINARY), dtype, str(path), 'value']
    if budget is not None:
        args.append(str(budget))
    return subprocess.run(args, capture_output=True, text=True)



def wire_fixture(dtype, body, modern=False, override=None):
    """Independent Thrift fixture with three required PLAIN physical values."""
    width = getattr(pa, dtype)().bit_width
    floating = dtype.startswith('float')
    physical = (4 if width == 32 else 5) if floating else (2 if width == 64 else 1)
    f = fields()
    schema, group, chunk, column = parts(f)
    node = schema[1]
    node[:] = [(1, T.I32, physical), (3, T.I32, 0), (4, T.STRING, b'value')]
    if not floating:
        signed = dtype.startswith('int')
        if modern:
            node.append((10, T.STRUCT, [(10, T.STRUCT, [(1, T.BYTE, width), (2, T.BOOL, signed)])]))
            # Modern annotations override deliberately conflicting legacy metadata.
            node.append((6, T.I32, 13 if signed else 17))
        else:
            node.append((6, T.I32, (15 if signed else 11) + [8,16,32,64].index(width)))
    if override is not None:
        put(node, override)
    put(column, (1, T.I32, physical))
    put(column, (3, T.LIST, (T.STRING, [b'value'])))
    payload = thrift_bytes(header_fields(0, len(body))) + body
    put(column, (6, T.I64, len(payload)))
    put(column, (7, T.I64, len(payload)))
    put(group, (2, T.I64, len(payload)))
    return encode(f, payload=payload)


def check_wire():
    accepted = rejected = 0
    for dtype in TYPES:
        width = getattr(pa, dtype)().bit_width
        physical_bytes = max(4, width // 8)
        if dtype.startswith('float'):
            raw = ([0x80000000, 0x7f800001, 0xffc12345] if width == 32 else
                   [0x8000000000000000, 0x7ff0000000000001, 0xfff8123456789abc])
            expected = raw
        else:
            signed = dtype.startswith('int')
            expected = [-(2**(width-1)) if signed else 0, 2**(width-int(signed))-1, -1 if signed else 1]
            raw = [v % 2**(physical_bytes*8) for v in expected]
        body = b''.join(v.to_bytes(physical_bytes, 'little') for v in raw)
        for modern in (False, True):
            path = OUT / f'wire-{dtype}-{modern}.parquet'
            path.write_bytes(wire_fixture(dtype, body, modern))
            result = probe(path, dtype)
            assert result.returncode == 0, (path, result.stdout, result.stderr)
            assert list(map(int, result.stdout.splitlines()[1:])) == expected
            accepted += 1
        for label, bad in [('short', body[:-1]), ('long', body + b'\0')]:
            path = OUT / f'wire-{dtype}-{label}.parquet'
            path.write_bytes(wire_fixture(dtype, bad))
            result = probe(path, dtype)
            assert result.returncode != 0 and 'PLAIN byte length' in result.stdout + result.stderr
            rejected += 1
        if width < 32:
            signed = dtype.startswith('int')
            for invalid in (2**(width-int(signed)), -(2**(width-1))-1 if signed else -1):
                bad = (invalid % 2**32).to_bytes(4, 'little') + b'\0'*8
                path = OUT / f'wire-{dtype}-invalid-{invalid}.parquet'
                path.write_bytes(wire_fixture(dtype, bad))
                result = probe(path, dtype)
                assert result.returncode != 0 and 'narrow range' in result.stdout + result.stderr
                rejected += 1
    return accepted, rejected

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['pixi', 'run', 'mojo', 'build', '-O3', '-I', 'src', '-I', '../NuMojo',
                    'tests/read_numeric.mojo', '-o', str(BINARY)], cwd=ROOT, check=True)
    files = rows = rejected = 0
    db = duckdb.connect()
    for dtype in TYPES:
        arrow_type = getattr(pa, dtype)()
        width = arrow_type.bit_width // 8
        if dtype.startswith('float'):
            special = [0.0, -0.0, 1.5, -2.25, float('inf'), -float('inf'), float('nan'),
                       struct.unpack('<f' if width == 4 else '<d', (1).to_bytes(width, 'little'))[0]]
        else:
            signed = dtype.startswith('int')
            special = [0, 1, -(2**(width*8-1)) if signed else 2**(width*8-1),
                       2**(width*8-int(signed))-1]
            if signed:
                special += [-1]
        patterns = {'required': (special * 137, False),
                    'nullable': ([None] + special + [None, None], True),
                    'multipage-nullable': ([None if i % 7 == 0 else special[i % len(special)] for i in range(1031)], True),
                    'all-null': ([None] * 131, True),
                    'empty': ([], True), 'empty-required': ([], False)}
        for version in ('1.0', '2.0'):
            for label, (values, nullable) in patterns.items():
                path = OUT / f'{dtype}-{version}-{label}.parquet'
                schema = pa.schema([pa.field('value', arrow_type, nullable=nullable)])
                table = pa.Table.from_arrays([pa.array(values, type=arrow_type)], schema=schema)
                pq.write_table(table, path, compression='NONE', use_dictionary=False,
                               data_page_version=version, data_page_size=128,
                               write_batch_size=31, row_group_size=257)
                expected = [encoded(v, dtype) for v in values]
                arrow = pq.read_table(path)['value']
                assert arrow.type == arrow_type
                assert [encoded(v, dtype) for v in arrow.to_pylist()] == expected
                duck = [r[0] for r in db.execute('SELECT value FROM read_parquet(?)', [str(path)]).fetchall()]
                assert len(duck) == len(values)
                for actual, wanted in zip(duck, values):
                    if wanted is not None and isinstance(wanted, float) and math.isnan(wanted):
                        assert math.isnan(actual)
                    else:
                        assert encoded(actual, dtype) == encoded(wanted, dtype)
                r = probe(path, dtype)
                assert r.returncode == 0, (path, r.stdout, r.stderr)
                lines = r.stdout.splitlines()
                assert lines[0] == f'{len(values)} {values.count(None)}'
                assert [None if v == 'null' else int(v) for v in lines[1:]] == expected, path
                budget = len(values)*width + ((len(values)+7)//8 if nullable else 0)
                assert probe(path, dtype, budget).returncode == 0, (path, budget)
                if budget:
                    assert probe(path, dtype, budget-1).returncode != 0, path
                    rejected += 1
                files += 1
                rows += len(values)
        for other in TYPES:
            if other != dtype:
                assert probe(OUT / f'{dtype}-1.0-required.parquet', other).returncode != 0, (dtype, other)
                rejected += 1
    # Logical annotations must never silently become ordinary numeric values.
    for name, arrow_type, values in [
        ('date', pa.date32(), [1]), ('time', pa.time32('ms'), [1]),
        ('timestamp', pa.timestamp('us'), [1]), ('decimal', pa.decimal128(8, 0), [1]),
        ('boolean', pa.bool_(), [True]),
    ]:
        path = OUT / f'{name}.parquet'
        pq.write_table(pa.table({'value': pa.array(values, type=arrow_type)}), path,
                       compression='NONE', use_dictionary=False, store_decimal_as_integer=True)
        for dtype in TYPES:
            assert probe(path, dtype).returncode != 0, (name, dtype)
            rejected += 1
    db.close()
    wire_accepted, wire_rejected = check_wire()
    result = {'files': files, 'values_and_nulls': rows, 'rejections': rejected, 'wire_accepted': wire_accepted, 'wire_rejected': wire_rejected,
              'oracles': ['PyArrow (float bits)', 'DuckDB (NaN semantics, other float bits)']}
    (OUT / 'results.json').write_text(json.dumps(result, indent=2))
    print(result)


if __name__ == '__main__':
    main()
