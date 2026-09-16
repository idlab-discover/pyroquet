"""Deterministic all-ten-type mixed corpus and three independent Parquet oracles.

Float manifests are buffer bits, preserving NaN/null distinctions. DuckDB's
Python scalar conversion permits NaN payload canonicalization only; Fastparquet
page decoding retains the exact bits and independent definition levels.
"""
from pathlib import Path
import hashlib
import json
import math
import struct
import subprocess

import duckdb
import fastparquet
from fastparquet import core, converted_types, encoding
from fastparquet.cencoding import ThriftObject
from fastparquet.compression import decompress_data
import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from check_compact_interop import read_struct
from check_metadata import put
from check_pages import thrift_bytes, T
from thrift.protocol.TCompactProtocol import TCompactProtocol
from thrift.transport.TTransport import TMemoryBuffer
from check_numeric import TYPES
from check_numeric_write import arrow_values, DUCK_TYPES, expected_plain

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/mixed-checks'
READ = OUT / 'read'
WRITE = OUT / 'roundtrip'
SEED = 20260916
LIMITATIONS = []


def fixture(rows=197, reverse=False):
    arrays, fields = [], []
    for c, dtype in enumerate(TYPES):
        typ = getattr(pa, dtype)()
        width = typ.bit_width
        signed = dtype.startswith('int')
        if dtype.startswith('float'):
            vals = ([0, 0x80000000, 0x7f800000, 0xff800000, 0x7f800001, 0xffc12345, 1]
                    if width == 32 else [0, 1 << 63, 0x7ff0000000000000,
                    0xfff0000000000000, 0x7ff0000000000001, 0xfff8123456789abc, 1])
        else:
            vals = [0, 1, -(1 << (width - 1)) if signed else 1 << (width - 1),
                    (1 << (width - int(signed))) - 1, -1 if signed else 17]
        nullable = c != 6
        valid = [not nullable or (i + c) % (5 + c) != 0 for i in range(rows)]
        raw = b''.join((vals[i % len(vals)] % (1 << width)).to_bytes(width // 8, 'little')
                       for i in range(rows))
        mask = bytes(sum(int(valid[i]) << (i % 8) for i in range(j, min(j + 8, rows)))
                     for j in range(0, rows, 8))
        arrays.append(pa.Array.from_buffers(typ, rows, [pa.py_buffer(mask) if nullable else None,
                                                      pa.py_buffer(raw)]))
        fields.append(pa.field('literal.dot' if c == 0 else dtype, typ, nullable=nullable))
    arrays.append(pa.nulls(rows, pa.uint16()))
    fields.append(pa.field('all_null', pa.uint16(), nullable=True))
    if reverse:
        arrays.reverse()
        fields.reverse()
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields))


def manifest(table):
    return [{'name': f.name, 'dtype': {'double': 'float64', 'float': 'float32'}[str(f.type)]
             if str(f.type) in ('double', 'float') else str(f.type), 'nullable': f.nullable,
             'values': arrow_values(table[f.name], 'int' if pa.types.is_signed_integer(f.type) else 'uint')}
            for f in table.schema]


def probe(path, expected, rows, projection=None, budget=1 << 30):
    args = [str(READ), str(path), str(budget)]
    if projection is not None:
        args += ['project', *projection]
    result = subprocess.run(args, capture_output=True, text=True)
    assert result.returncode == 0, (path, result.stdout, result.stderr)
    lines = iter(result.stdout.splitlines())
    assert next(lines) == f'{rows} {len(expected)}'
    for col in expected:
        assert next(lines) == col['name']
        assert next(lines) == f"{col['dtype']} {int(col['nullable'])}"
        assert [None if (v := next(lines)) == 'null' else int(v) for _ in range(rows)] == col['values']
    assert list(lines) == []


def compare(path, expected, rows, db):
    table = pq.read_table(path)
    assert manifest(table) == expected, path
    actual = db.execute('SELECT * FROM read_parquet(?)', [str(path)]).fetchall()
    assert [str(d[1]) for d in db.description] == [DUCK_TYPES[c['dtype']] for c in expected]
    assert [d[0] for d in db.description] == [c['name'] for c in expected]
    assert len(actual) == rows
    for i, row in enumerate(actual):
        for value, col in zip(row, expected):
            wanted = col['values'][i]
            if wanted is None:
                assert value is None
            elif col['dtype'].startswith('float'):
                width = int(col['dtype'][5:]) // 8
                fmt = '<f' if width == 4 else '<d'
                decoded = struct.unpack(fmt, wanted.to_bytes(width, 'little'))[0]
                assert value is not None
                if math.isnan(decoded):
                    assert math.isnan(value)
                else:
                    assert struct.pack(fmt, value) == wanted.to_bytes(width, 'little')
            else:
                assert value == wanted
    # Public path always attempted. Known V2 decoder defects are recorded,
    # with complete validity/bits independently checked below.
    pf = fastparquet.ParquetFile(path)
    try:
        frame = pf.to_pandas()
        assert list(frame.columns) == [c['name'] for c in expected]
        assert len(frame) == rows
        for col in expected:
            series = frame[col['name']]
            assert str(series.dtype).lower() == col['dtype']
            for value, wanted in zip(series, col['values']):
                if wanted is None:
                    assert pd.isna(value)
                elif not col['dtype'].startswith('float'):
                    assert int(value) == wanted
                else:
                    width = int(col['dtype'][5:]) // 8
                    fmt = '<f' if width == 4 else '<d'
                    decoded = struct.unpack(fmt, wanted.to_bytes(width, 'little'))[0]
                    assert math.isnan(value) if math.isnan(decoded) else struct.pack(fmt, value) == wanted.to_bytes(width, 'little')
    except (IndexError, TypeError) as error:
        assert ('boolean index did not match' in str(error) or str(error) == 'an integer is required'), str(error)
        LIMITATIONS.append({'file': path.name, 'oracle': 'Fastparquet public reader',
                            'status': 'defect', 'error': str(error)})


def wire(path, expected, version, codec):
    """Independently verify each chunk, every PLAIN byte and every null bit."""
    pf = fastparquet.ParquetFile(path)
    raw = path.read_bytes()
    previous_end, row_start = 4, 0
    for group in pf.row_groups:
        assert len(group.columns) == len(expected)
        group_uncompressed = group_compressed = 0
        assert 0 < group.num_rows <= 61
        for c, (chunk, col) in enumerate(zip(group.columns, expected)):
            md = chunk.meta_data
            assert md.path_in_schema == [col['name']]
            se = pf.schema.schema_element(md.path_in_schema)
            assert se.repetition_type == int(col['nullable'])
            assert md.num_values == group.num_rows
            assert md.codec == (codec if codec >= 0 else c % 2)
            assert md.data_page_offset == previous_end
            stream = encoding.NumpyIO(raw)
            stream.seek(previous_end)
            offset, total = 0, 0
            while offset < group.num_rows:
                start = stream.tell()
                header = ThriftObject.from_buffer(stream, 'PageHeader')
                assert header.type == (0 if version == 1 else 3)
                dh = header.data_page_header if version == 1 else header.data_page_header_v2
                assert dh.encoding == 0
                assert 0 < dh.num_values <= 7 + c * 3
                body_start = stream.tell()
                body = raw[body_start:body_start + header.compressed_page_size]
                total += body_start - start + header.uncompressed_page_size
                wanted = col['values'][row_start + offset:row_start + offset + dh.num_values]
                if version == 1:
                    plain = bytes(decompress_data(np.frombuffer(body, dtype='uint8'), header.uncompressed_page_size, md.codec)) if md.codec else body
                    defs, reps, vals = core.read_data_page(stream, pf.schema, header, md)
                    assert reps is None
                    valid = [True] * dh.num_values if defs is None else (defs == 1).tolist()
                    vals = converted_types.convert(vals, se)
                    got = vals.view('uint' + col['dtype'][5:]).tolist() if col['dtype'].startswith('float') else vals.tolist()
                    assert got == [v for v in wanted if v is not None]
                    levels = 4 + int.from_bytes(plain[:4], 'little') if col['nullable'] else 0
                else:
                    assert dh.num_rows == dh.num_values
                    assert dh.num_nulls == wanted.count(None)
                    assert dh.repetition_levels_byte_length == 0
                    levels = dh.definition_levels_byte_length
                    plain = body[:levels] + bytes(decompress_data(np.frombuffer(body[levels:], dtype='uint8'), header.uncompressed_page_size - levels, md.codec)) if dh.is_compressed and md.codec else body
                    valid = [True] * dh.num_values
                    if col['nullable']:
                        defs = np.empty(dh.num_values, dtype='uint8')
                        core.encoding.read_rle_bit_packed_hybrid(encoding.NumpyIO(body[:levels]), 1, levels, encoding.NumpyIO(defs), itemsize=1)
                        valid = (defs == 1).tolist()
                    # Run Fastparquet's actual V2 page reader in a bounded buffer.
                    dtype = col['dtype']
                    assign = (pd.array(np.zeros(dh.num_values, dtype=dtype), dtype=dtype.replace('int', 'Int').replace('uInt', 'UInt'))
                              if not dtype.startswith('float') else np.zeros(dh.num_values, dtype=dtype))
                    core.read_data_page_v2(encoding.NumpyIO(body), pf.schema, se, dh, md, None, assign, 0, False, 0, header)
                    vals = assign._data[np.array(valid)] if hasattr(assign, '_mask') else assign[np.array(valid)]
                    got = vals.view('uint' + dtype[5:]).tolist() if dtype.startswith('float') else vals.tolist()
                    assert got == [v for v in wanted if v is not None]
                    stream.seek(body_start + len(body))
                assert valid == [v is not None for v in wanted]
                assert plain[levels:] == expected_plain(wanted, col['dtype'])
                offset += dh.num_values
            assert offset == group.num_rows
            assert stream.tell() - previous_end == md.total_compressed_size
            assert total == md.total_uncompressed_size
            assert md.statistics.null_count == col['values'][row_start:row_start + group.num_rows].count(None)
            previous_end = stream.tell()
            group_uncompressed += total
            group_compressed += md.total_compressed_size
        assert group.total_byte_size == group_uncompressed
        assert group.total_compressed_size == group_compressed
        row_start += group.num_rows
    assert row_start == pf.fmd.num_rows
    assert previous_end == len(raw) - 8 - int.from_bytes(raw[-8:-4], 'little')


def projection_structure_checks():
    table = pa.table({'good': pa.array([1, None, 3], pa.int32()), 'unsupported': ['a', 'b', 'c']})
    path = OUT / 'unsupported-unselected.parquet'
    pq.write_table(table, path, use_dictionary=False, compression='NONE')
    expected = manifest(table.select(['good']))
    probe(path, expected, 3, ['good'])
    probe(path, [], 3, [])
    assert subprocess.run([str(READ), str(path), str(1 << 30)], capture_output=True).returncode != 0
    raw = path.read_bytes()
    start = len(raw) - 8 - int.from_bytes(raw[-8:-4], 'little')
    for label in ('offset', 'rows', 'duplicate'):
        fmd = read_struct(TCompactProtocol(TMemoryBuffer(raw[start:-8])))
        def field(fields, number):
            return next(value for key, kind, value in fields if key == number)
        schema = field(fmd, 2)[1]
        group = field(fmd, 4)[1][0]
        md = field(field(group, 1)[1][1], 3)
        if label == 'offset':
            put(md, (9, T.I64, 1))
        elif label == 'rows':
            put(md, (5, T.I64, 2))
        else:
            put(schema[2], (4, T.STRING, b'good'))
            put(md, (3, T.LIST, (T.STRING, [b'good'])))
        footer = thrift_bytes(fmd)
        bad = OUT / f'bad-unselected-{label}.parquet'
        bad.write_bytes(raw[:start] + footer + len(footer).to_bytes(4, 'little') + b'PAR1')
        for selected in ([], ['good']):
            result = subprocess.run([str(READ), str(bad), str(1 << 30), 'project', *selected], capture_output=True)
            assert result.returncode != 0, (label, selected)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for source, target in [('read_mixed', READ), ('roundtrip_mixed', WRITE)]:
        subprocess.run(['pixi', 'run', 'mojo', 'build', '-O3', '-I', 'src', '-I', '../NuMojo', f'tests/{source}.mojo', '-o', str(target)], cwd=ROOT, check=True)
    db = duckdb.connect()
    projection_structure_checks()
    records = []
    for label, table in [('mixed', fixture()), ('reverse', fixture(reverse=True)), ('empty', fixture(0))]:
        expected = manifest(table)
        source = OUT / f'{label}-arrow.parquet'
        pq.write_table(table, source, use_dictionary=False, compression='NONE', row_group_size=61,
                       data_page_size=128, write_batch_size=13)
        probe(source, expected, table.num_rows)
        compare(source, expected, table.num_rows, db)
        for selected in ([], [expected[-1]['name'], expected[0]['name']], [c['name'] for c in expected[::-1]]):
            probe(source, [next(c for c in expected if c['name'] == n) for n in selected], table.num_rows, selected)
        for selected in (['missing'], [expected[0]['name']] * 2):
            r = subprocess.run([str(READ), str(source), str(1 << 30), 'project', *selected], capture_output=True)
            assert r.returncode != 0
        budget = sum(table.num_rows * (getattr(pa, c['dtype'])().bit_width // 8) + ((table.num_rows + 7) // 8 if c['nullable'] else 0) for c in expected)
        probe(source, expected, table.num_rows, budget=budget)
        if budget:
            assert subprocess.run([str(READ), str(source), str(budget - 1)], capture_output=True).returncode != 0
        for version in (1, 2):
            for codec in (0, 1, -1):
                target = OUT / f'{label}-native-v{version}-c{codec}.parquet'
                target.unlink(missing_ok=True)
                result = subprocess.run([str(WRITE), str(source), str(target), str(version), str(codec)], capture_output=True, text=True)
                assert result.returncode == 0, (target, result.stdout, result.stderr)
                probe(target, expected, table.num_rows)
                compare(target, expected, table.num_rows, db)
                wire(target, expected, version, codec)
                records.append({'file': target.name, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                                'producer': 'Pyroquet', 'page_version': version, 'codec': codec, 'schema_and_values': expected})
        # DuckDB actual Parquet writer; materialization can canonicalize NaNs.
        duck = OUT / f'{label}-duck.parquet'
        duck.unlink(missing_ok=True)
        db.execute("COPY (SELECT * FROM read_parquet('" + str(source).replace("'", "''") + "')) TO '" + str(duck).replace("'", "''") + "' (FORMAT PARQUET, COMPRESSION UNCOMPRESSED)")
        duck_expected = manifest(pq.read_table(duck))
        if table.num_rows:
            result = subprocess.run([str(READ), str(duck), str(1 << 30)], capture_output=True, text=True)
            assert result.returncode != 0
            assert 'Excess bit-packed definition levels' in result.stdout + result.stderr
            pf = fastparquet.ParquetFile(duck)
            md = next(c.meta_data for c in pf.row_groups[0].columns if c.meta_data.path_in_schema == ['literal.dot'])
            raw = duck.read_bytes()
            stream = encoding.NumpyIO(raw)
            stream.seek(md.data_page_offset)
            header = ThriftObject.from_buffer(stream, 'PageHeader')
            body = raw[stream.tell():stream.tell() + header.compressed_page_size]
            assert header.type == 0 and md.codec == 0
            assert body[4] == 0x41  # 32 groups = 256 entries for 197 rows.
            assert 256 - header.data_page_header.num_values > 7
            LIMITATIONS.append({'file': duck.name, 'oracle': 'DuckDB writer', 'status': 'invalid fixture under strict final-group padding policy',
                                'feature': '197-row definition stream pads to 256 entries, beyond one final group; native rejection verified'})
        else:
            probe(duck, duck_expected, table.num_rows)
        compare(duck, duck_expected, table.num_rows, db)
        records.append({'file': duck.name, 'sha256': hashlib.sha256(duck.read_bytes()).hexdigest(), 'producer': 'DuckDB', 'schema_and_values': duck_expected})
        records.append({'file': source.name, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'producer': 'PyArrow', 'schema_and_values': expected})
    # Aligned, fully valid values avoid DuckDB's extra packed groups while
    # exercising its actual dictionary writer for all ten types and float bits.
    table = fixture(256).drop_columns(['all_null'])
    arrays = [pa.Array.from_buffers(c.type, len(c), [None, c.chunk(0).buffers()[1]]) for c in table.columns]
    table = pa.Table.from_arrays(arrays, names=table.column_names)
    source = OUT / 'duck-aligned-input.parquet'
    path = OUT / 'duck-aligned.parquet'
    path.unlink(missing_ok=True)
    pq.write_table(table, source, use_dictionary=False, compression='NONE')
    db.execute("COPY (SELECT * FROM read_parquet('" + str(source).replace("'", "''") + "')) TO '" + str(path).replace("'", "''") + "' (FORMAT PARQUET, COMPRESSION UNCOMPRESSED)")
    expected = manifest(pq.read_table(path))
    probe(path, expected, 256)
    compare(path, expected, 256, db)
    records.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'producer': 'DuckDB',
                    'schema_and_values': expected, 'options': {'rows': 256, 'nulls': False}})
    # External producer mixes codecs independently across columns and page
    # versions, with dictionary and PLAIN encodings in the same file.
    table = fixture()
    for version in ('1.0', '2.0'):
        for dictionaries in (False, [table.column_names[i] for i in range(0, 11, 2)]):
            path = OUT / f'external-v{version}-dictionary-{bool(dictionaries)}.parquet'
            pq.write_table(table, path, use_dictionary=dictionaries,
                           compression={name: 'snappy' if i % 2 else 'NONE' for i, name in enumerate(table.column_names)},
                           data_page_version=version, row_group_size=61, data_page_size=128,
                           write_batch_size=13)
            expected = manifest(pq.read_table(path))
            assert expected == manifest(table)
            probe(path, expected, table.num_rows)
            compare(path, expected, table.num_rows, db)
            records.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                            'producer': 'PyArrow', 'page_version': version, 'dictionary': dictionaries,
                            'codec': 'alternating NONE/SNAPPY', 'schema_and_values': expected})
    # Fastparquet's pandas writer conflates float NaN and null. Exercise its
    # actual writer with finite required floats and nullable exact integer arrays;
    # NaN payload/independent float null writes remain explicitly unsupported.
    frame = {}
    original = manifest(fixture())
    nullable = []
    for col in original:
        dtype, name = col['dtype'], col['name']
        if dtype.startswith('float'):
            frame[name] = np.resize(np.array([0.0, -0.0, 1.5, -2.25], dtype=dtype), 197)
        else:
            frame[name] = pd.array(col['values'], dtype=dtype.replace('int', 'Int').replace('uInt', 'UInt'))
            if col['nullable']:
                nullable.append(name)
    path = OUT / 'fastparquet-writer.parquet'
    fastparquet.write(path, pd.DataFrame(frame), compression=None, has_nulls=nullable,
                      row_group_offsets=61, write_index=False)
    expected = manifest(pq.read_table(path))
    for col in expected:
        if not col['dtype'].startswith('float'):
            assert col['values'] == next(c['values'] for c in original if c['name'] == col['name'])
    rejection = subprocess.run([str(READ), str(path), str(1 << 30)], capture_output=True, text=True)
    assert rejection.returncode != 0
    assert 'PLAIN byte length' in rejection.stdout + rejection.stderr
    # Preserve and prove the known Fastparquet V1 padding defect: every page
    # contains eight extraneous zero bytes beyond its declared physical values.
    pf = fastparquet.ParquetFile(path)
    raw = path.read_bytes()
    for group in pf.row_groups:
        for chunk in group.columns:
            md = chunk.meta_data
            stream = encoding.NumpyIO(raw)
            stream.seek(md.data_page_offset)
            header = ThriftObject.from_buffer(stream, 'PageHeader')
            assert header.type == 0 and md.codec == 0
            body = raw[stream.tell():stream.tell() + header.compressed_page_size]
            defs, reps, vals = core.read_data_page(stream, pf.schema, header, md)
            count = header.data_page_header.num_values if defs is None else int(sum(defs == 1))
            levels = 0 if defs is None else 4 + int.from_bytes(body[:4], 'little')
            width = {1: 4, 2: 8, 4: 4, 5: 8}[md.type]
            assert len(body) - levels - count * width == 8
            assert body[-8:] == bytes(8)
    compare(path, expected, 197, db)
    LIMITATIONS.append({'file': path.name, 'oracle': 'Fastparquet writer', 'status': 'invalid fixture',
                        'feature': 'V1 emits eight padded bytes after PLAIN values; native strict rejection verified'})
    records.append({'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                    'producer': 'Fastparquet', 'options': {'compression': None, 'has_nulls': nullable, 'row_group_offsets': 61},
                    'schema_and_values': expected})
    LIMITATIONS.append({'oracle': 'Fastparquet pandas writer', 'status': 'unsupported',
                        'feature': 'simultaneous valid NaN payloads and independent float nulls; finite required floats tested'})
    # A late last-column page budget failure and late footer failure preserve the
    # target and clean up staging; collisions also preserve existing bytes.
    source = OUT / 'mixed-arrow.parquet'
    for label, options in [('footer', ['1', '0']), ('late-column', ['67108864', '1'])]:
        target = OUT / f'failure-{label}.parquet'
        target.unlink(missing_ok=True)
        before = set(OUT.iterdir())
        result = subprocess.run([str(WRITE), str(source), str(target), '1', '0', *options], capture_output=True)
        assert result.returncode != 0
        assert set(OUT.iterdir()) == before
    target = OUT / 'collision.parquet'
    target.write_bytes(b'existing destination')
    before = set(OUT.iterdir())
    assert subprocess.run([str(WRITE), str(source), str(target), '1', '0'], capture_output=True).returncode != 0
    assert target.read_bytes() == b'existing destination'
    assert set(OUT.iterdir()) == before
    matrix = []
    for record in records:
        name = record['file']
        defects = [item for item in LIMITATIONS if item.get('file') == name]
        matrix.append({'file': name, 'PyArrow read values/types/nulls/float bits': 'pass',
                       'DuckDB read values/types/nulls/float non-NaN bits': 'pass',
                       'Fastparquet public read': 'defect' if any(item.get('oracle') == 'Fastparquet public reader' for item in defects) else 'pass',
                       'Fastparquet page values/nulls/float bits and wire layout': 'pass' if record['producer'] == 'Pyroquet' else 'not exercised by this harness',
                       'Pyroquet read values/types/nulls/float bits':
                           'invalid fixture; strict rejection passed' if any(item['status'].startswith('invalid fixture') for item in defects)
                           else 'pass'})
    output = {'seed': SEED, 'versions': {'pyarrow': pa.__version__, 'duckdb': duckdb.__version__, 'fastparquet': fastparquet.__version__},
              'fixtures': records, 'matrix': matrix, 'limitations': LIMITATIONS}
    (OUT / 'manifest.json').write_text(json.dumps(output, indent=2))
    print(json.dumps({'fixtures': len(records), 'limitations': LIMITATIONS}, indent=2))


if __name__ == '__main__':
    main()
