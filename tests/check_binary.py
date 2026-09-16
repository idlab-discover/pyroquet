"""Deterministic raw-byte/Boolean fixtures and full-value three-reader checks.

Run with build/oracle-uv/bin/python; generated files/manifests stay in build/.
Seed 20260916. No UTF-8 capability is implemented or expected.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import duckdb
import fastparquet
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/binary-checks'
BINARY = ROOT / 'build/roundtrip-binary'
RESULTS = []


def values():
    raw = [b'', b'\0', b'\xff\x80\0', b'prefix' * 90, bytes(range(256))]
    return {
        'flag': [None if i % 5 == 0 else i % 2 == 0 for i in range(81)],
        'raw': [None if i % 7 == 0 else raw[i % len(raw)] for i in range(81)],
        'fixed': [None if i % 9 == 0 else bytes([i, 0, 255]) for i in range(81)],
        'number': [None if i % 11 == 0 else i - 40 for i in range(81)],
    }


def native(path, expected):
    p = subprocess.run([str(BINARY), str(path)], capture_output=True, text=True)
    assert p.returncode == 0, (path, p.stderr)
    lines = iter(p.stdout.splitlines())
    assert next(lines) == f'rows {len(next(iter(expected.values())))}'
    kinds = {'flag': (11, 0), 'raw': (12, 0), 'fixed': (13, 3), 'number': (6, 0)}
    for name, vals in expected.items():
        kind, width = kinds[name]
        assert next(lines) == f'column {name} {kind} {width}'
        for value in vals:
            wanted = 'null' if value is None else ('bytes' + ''.join(f' {b}' for b in value) if isinstance(value, bytes) else str(int(value)))
            assert next(lines) == wanted, (path, name, value)
    assert next(lines, None) is None


def known_fastparquet_error(path, exc):
    """Recognize only failures reproduced in the retained deterministic corpus."""
    arrow_v2 = {
        f'arrow-2.0-{codec}-{dictionary}.parquet'
        for codec in ('NONE', 'SNAPPY') for dictionary in (False, True)
    }
    if path.name in arrow_v2:
        return type(exc) is ValueError and str(exc) == (
            'NumPy boolean array indexing assignment cannot assign 23 input '
            'values to the 18 output values where the mask is true'
        )
    sizes = {
        **{f'native-v2-codec{codec}.parquet': (7, 19) for codec in (0, 1)},
        **{f'wire-bool-rle-v2-c{codec}.parquet': (9, 12) for codec in (0, 1)},
    }
    if path.name in sizes:
        values, mask = sizes[path.name]
        return type(exc) is IndexError and str(exc) == (
            'boolean index did not match indexed array along axis 0; '
            f'size of axis is {values} but size of corresponding boolean '
            f'axis is {mask}'
        )
    return False


def known_fastparquet_values(path, expected, actual):
    """Pin complete known value mismatches; new null/value differences must fail."""
    if path.name in {f'wire-bool-rle-v1-c{codec}.parquet' for codec in (0, 1)}:
        return expected == {'flag': [
            True, None, False, True, None, True, False, True, True,
            False, True, None,
        ]} and actual == {'flag': [
            False, None, True, False, None, True, True, False, True,
            False, True, None,
        ]}
    fixed_files = {
        f'wire-fixed-mixed-v{version}-c{codec}.parquet'
        for version in (1, 2) for codec in (0, 1)
    }
    if path.name in fixed_files and set(expected) == {'fixed'}:
        stripped = {'fixed': [
            None if value is None else value.rstrip(b'\0')
            for value in expected['fixed']
        ]}
        return actual == stripped
    return False


def readers(path, expected, fixed=True):
    arrow = pq.read_table(path)
    assert arrow.schema.names == list(expected), path
    assert arrow.to_pydict() == expected, path
    if 'flag' in expected:
        assert arrow.schema.field('flag').type == pa.bool_()
    if 'raw' in expected:
        assert arrow.schema.field('raw').type == pa.binary()
    if 'fixed' in expected:
        assert arrow.schema.field('fixed').type == pa.binary(3)
    if 'number' in expected:
        assert arrow.schema.field('number').type == pa.int32()
    RESULTS.append([path.name, 'pyarrow-read', 'pass'])
    con = duckdb.connect()
    query = con.execute('select * from read_parquet(?)', [str(path)])
    duck_types = {'flag': 'BOOLEAN', 'raw': 'BLOB', 'fixed': 'BLOB', 'number': 'INTEGER'}
    assert [(field[0], str(field[1])) for field in query.description] == [
        (name, duck_types[name]) for name in expected
    ], path
    result = query.fetchall()
    assert result == list(zip(*expected.values())), path
    RESULTS.append([path.name, 'duckdb-read', 'pass'])
    parquet = fastparquet.ParquetFile(path)
    assert parquet.columns == list(expected), path
    physical_types = {'flag': 0, 'raw': 6, 'fixed': 7, 'number': 1}
    for name in expected:
        field = parquet.schema.schema_element([name])
        assert field.type == physical_types[name], (path, name, field.type)
        if name == 'fixed':
            assert field.type_length == 3, path
    try:
        frame = parquet.to_pandas()
        actual = {name: [None if pd.isna(v) else v for v in frame[name].tolist()] for name in expected}
    except (ValueError, IndexError) as exc:
        if not known_fastparquet_error(path, exc):
            raise
        RESULTS.append([path.name, 'fastparquet-read', 'defect', repr(exc)[:400]])
    else:
        if actual == expected:
            RESULTS.append([path.name, 'fastparquet-read', 'pass'])
        else:
            assert known_fastparquet_values(path, expected, actual), (path, actual)
            RESULTS.append([path.name, 'fastparquet-read', 'defect', repr(actual)[:400]])


def assert_plain_wire(path, expected):
    import struct
    from fastparquet.cencoding import ThriftObject, NumpyIO
    from fastparquet.compression import decompress_data
    from check_numeric_dictionary import packed
    pf = fastparquet.ParquetFile(path)
    raw = path.read_bytes()
    group_start = 0
    for group in pf.row_groups:
        for c, (name, vals) in enumerate(expected.items()):
            md = group.columns[c].meta_data
            stream = NumpyIO(raw)
            stream.seek(md.data_page_offset)
            start = group_start
            raw_total = 0
            while start < group_start + group.num_rows:
                header_start = stream.tell()
                h = ThriftObject.from_buffer(stream, 'PageHeader')
                header_size = stream.tell() - header_start
                body = raw[stream.tell():stream.tell()+h.compressed_page_size]
                stream.seek(stream.tell() + len(body))
                dh = h.data_page_header if h.type == 0 else h.data_page_header_v2
                page_vals = vals[start:start+dh.num_values]
                expected_levels = packed([int(v is not None) for v in page_vals], 1)
                if h.type == 0:
                    body = bytes(decompress_data(body, h.uncompressed_page_size, md.codec))
                    level_size = int.from_bytes(body[:4], 'little')
                    assert body[4:4+level_size] == expected_levels
                    payload = body[4+level_size:]
                else:
                    level_size = dh.definition_levels_byte_length
                    assert body[:level_size] == expected_levels
                    payload = body[level_size:]
                    if dh.is_compressed:
                        payload = bytes(decompress_data(payload, h.uncompressed_page_size-level_size, md.codec))
                    assert dh.num_nulls == page_vals.count(None)
                    assert dh.num_rows == len(page_vals)
                present = [v for v in page_vals if v is not None]
                if name == 'flag':
                    wanted = sum(int(v) << i for i,v in enumerate(present)).to_bytes((len(present)+7)//8, 'little')
                elif name == 'number':
                    wanted = b''.join(struct.pack('<i', v) for v in present)
                else:
                    wanted = b''.join((struct.pack('<I', len(v)) if name == 'raw' else b'') + v for v in present)
                assert payload == wanted, (path, name, start)
                raw_total += header_size + h.uncompressed_page_size
                start += dh.num_values
            assert start == group_start + group.num_rows
            assert stream.tell() == md.data_page_offset + md.total_compressed_size
            assert raw_total == md.total_uncompressed_size
            assert md.statistics.null_count == vals[group_start:start].count(None)
        group_start += group.num_rows
    assert group_start == len(next(iter(expected.values())))


def verify_fast_padding(path, vals, name):
    from fastparquet.cencoding import ThriftObject, NumpyIO
    from fastparquet.compression import decompress_data
    pf = fastparquet.ParquetFile(path)
    md = pf.row_groups[0].columns[0].meta_data
    raw = path.read_bytes()
    stream = NumpyIO(raw)
    stream.seek(md.data_page_offset)
    header = ThriftObject.from_buffer(stream, 'PageHeader')
    body = bytes(decompress_data(raw[stream.tell():stream.tell()+header.compressed_page_size], header.uncompressed_page_size, md.codec))
    level_size = int.from_bytes(body[:4], 'little')
    present = [v for v in vals if v is not None]
    expected = (len(present)+7)//8 if name == 'flag' else sum(len(v)+(4 if name == 'raw' else 0) for v in present)
    assert len(body) - 4 - level_size - expected == 8 + int(name == 'flag' and len(present) % 8 == 0), (path, len(body), level_size, expected)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    expected = values()
    schema = pa.schema([pa.field('flag', pa.bool_()), pa.field('raw', pa.binary()), pa.field('fixed', pa.binary(3)), pa.field('number', pa.int32())])
    table = pa.Table.from_pydict(expected, schema=schema)
    for version in ('1.0', '2.0'):
        for codec in ('NONE', 'SNAPPY'):
            for dictionary in (False, True):
                source = OUT / f'arrow-{version}-{codec}-{dictionary}.parquet'
                pq.write_table(table, source, use_dictionary=dictionary, data_page_version=version, compression=codec, row_group_size=23, data_page_size=128, write_batch_size=9)
                native(source, expected)
                readers(source, expected)
                RESULTS.append([source.name, 'pyarrow-write-native-read', 'pass'])
    source = OUT / 'arrow-1.0-NONE-False.parquet'
    for version in (1, 2):
        for codec in (0, 1):
            output = OUT / f'native-v{version}-codec{codec}.parquet'
            output.unlink(missing_ok=True)
            subprocess.run([str(BINARY), str(source), str(output), str(version), str(codec)], check=True, stdout=subprocess.DEVNULL)
            native(output, expected)
            readers(output, expected)
            assert_plain_wire(output, expected)
    # DuckDB's BLOB writer preserves arbitrary bytes but has no fixed-width type.
    con = duckdb.connect()
    for codec in ('UNCOMPRESSED', 'SNAPPY'):
        output = OUT / f'duck-{codec}.parquet'
        output.unlink(missing_ok=True)
        con.execute(f"COPY (SELECT flag, raw, number FROM read_parquet('{source}')) TO '{output}' (FORMAT PARQUET, COMPRESSION {codec}, ROW_GROUP_SIZE 2048)")
        subset = {k: expected[k] for k in ('flag', 'raw', 'number')}
        p = subprocess.run([str(BINARY), str(output)], capture_output=True, text=True)
        if p.returncode:
            assert 'Excess bit-packed definition levels' in p.stdout + p.stderr, (p.returncode, p.stdout, p.stderr)
            RESULTS.append([output.name, 'duckdb-write-native-read', 'invalid fixture', 'Known excess final-group definition padding; retained unchanged'])
        else:
            native(output, subset)
            RESULTS.append([output.name, 'duckdb-write-native-read', 'pass'])
        readers(output, subset)
        aligned = {k: ([x if x is not None else (False if k == 'flag' else b'' if k == 'raw' else 0) for x in v] * 4)[:256] for k, v in subset.items()}
        input_path = OUT / 'duck-aligned-input.parquet'
        pq.write_table(pa.Table.from_pydict(aligned, schema=pa.schema([schema.field(k) for k in aligned])), input_path, row_group_size=256)
        aligned_path = OUT / f'duck-aligned-{codec}.parquet'
        aligned_path.unlink(missing_ok=True)
        con.execute(f"COPY (SELECT * FROM read_parquet('{input_path}')) TO '{aligned_path}' (FORMAT PARQUET, COMPRESSION {codec})")
        native(aligned_path, aligned)
        readers(aligned_path, aligned)
        RESULTS.append([aligned_path.name, 'duckdb-write-native-read', 'pass'])
    RESULTS.append(['fixed', 'duckdb-write', 'unsupported', 'BLOB has no fixed-width identity'])
    # Fastparquet byte objects need explicit bytes encoding, never inferred text.
    for codec in (None, 'SNAPPY'):
        output = OUT / f'fast-{codec}.parquet'
        frame = pd.DataFrame({'flag': pd.array(expected['flag'], dtype='boolean'), 'raw': expected['raw'], 'number': pd.array(expected['number'], dtype='Int32')})
        fastparquet.write(output, frame, compression=codec, object_encoding={'raw': 'bytes'}, has_nulls=True, write_index=False)
        p = subprocess.run([str(BINARY), str(output)], capture_output=True, text=True)
        if p.returncode:
            assert 'Boolean PLAIN length mismatch' in p.stdout + p.stderr
            verify_fast_padding(output, expected['flag'], 'flag')
            RESULTS.append([output.name, 'fastparquet-write-native-read', 'invalid fixture', 'Surplus PLAIN padding verified independently'])
        else:
            subset = {k: expected[k] for k in ('flag', 'raw', 'number')}
            native(output, subset)
            RESULTS.append([output.name, 'fastparquet-write-native-read', 'pass'])
    for name, vals, options in [
        ('raw', [b'', None, b'\0\xff', b'\xff\x80'], {}),
        ('fixed', [b'\0\xff\0', None, b'\0\xff\x80'], {'fixed_text': {'fixed': 3}}),
        ('flag', [True, False, None, True], {}),
    ]:
        output = OUT / f'fast-{name}-only.parquet'
        col = pd.array(vals, dtype='boolean') if name == 'flag' else vals
        fastparquet.write(output, pd.DataFrame({name: col}), object_encoding='bytes', write_index=False, **options)
        result = subprocess.run([str(BINARY), str(output)], capture_output=True, text=True)
        assert result.returncode != 0
        verify_fast_padding(output, vals, name)
        RESULTS.append([output.name, 'fastparquet-write-native-read', 'invalid fixture', 'Surplus PLAIN padding verified independently'])
    text_path = OUT / 'deferred-string.parquet'
    pq.write_table(pa.table({'raw': ['hello', 'é', None]}), text_path)
    rejected = subprocess.run([str(BINARY), str(text_path)], capture_output=True, text=True)
    assert rejected.returncode != 0 and 'Selected field is not a supported flat column' in rejected.stdout + rejected.stderr
    manifest = {k: [v.hex() if isinstance(v, bytes) else v for v in vs] for k, vs in expected.items()}
    (OUT / 'manifest.json').write_text(json.dumps({'seed': 20260916, 'versions': {'pyarrow': pa.__version__, 'duckdb': duckdb.__version__, 'fastparquet': fastparquet.__version__}, 'values': manifest, 'sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.glob('*.parquet')}}, indent=2))
    (OUT / 'results.json').write_text(json.dumps(RESULTS, indent=2))
    print(f'{len(RESULTS)} oracle entries; {sum(r[2] == "pass" for r in RESULTS)} passes')
    for r in RESULTS:
        if r[2] != 'pass':
            print(*r)


if __name__ == '__main__':
    main()
