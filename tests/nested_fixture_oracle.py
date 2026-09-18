"""Independent nested fixtures, actual page/level evidence and native parity.

Development only. Local authority: parquet-format README Nested Encoding/Nulls/
Data Pages, LogicalTypes Lists/backward compatibility, Encodings RLE hybrid.
Generated artifacts and full reports remain under build/nested-fixtures.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys

import duckdb
import fastparquet
from fastparquet.cencoding import NumpyIO, ThriftObject
from fastparquet.compression import decompress_data
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/nested-fixtures'
KINDS = {'uint32': 1, 'int8': 2, 'uint8': 3, 'int16': 4, 'uint16': 5,
         'int32': 6, 'int64': 7, 'uint64': 8, 'float': 9, 'double': 10,
         'bool': 11, 'binary': 12}


def hybrid(data, width, count):
    """Bounded independent hybrid level decoder, permitting final packed padding."""
    values, pos = [], 0
    while len(values) < count:
        header = shift = 0
        while True:
            if pos >= len(data) or shift > 63:
                raise ValueError('truncated/oversized hybrid header')
            byte = data[pos]; pos += 1
            header |= (byte & 127) << shift
            if not byte & 128:
                break
            shift += 7
        if header == 0:
            raise ValueError('zero hybrid run')
        if header & 1:
            n = (header >> 1) * 8
            size = n * width // 8
            if pos + size > len(data):
                raise ValueError('truncated hybrid packed run')
            packed = int.from_bytes(data[pos:pos + size], 'little'); pos += size
            take = min(n, count - len(values))
            if n - take > 7:
                raise ValueError('excess packed run')
            values.extend((packed >> (i * width)) & ((1 << width) - 1) for i in range(take))
        else:
            n = header >> 1
            size = (width + 7) // 8
            if n > count - len(values) or pos + size > len(data):
                raise ValueError('truncated/excess hybrid RLE run')
            value = int.from_bytes(data[pos:pos + size], 'little'); pos += size
            if value >= 1 << width:
                raise ValueError('level wider than declared bit width')
            values.extend([value] * n)
    if pos != len(data):
        raise ValueError('extra level bytes')
    return values


def page_evidence(path):
    pf = fastparquet.ParquetFile(path)
    raw = path.read_bytes()
    records = []
    for gi, group in enumerate(pf.row_groups):
        for col in group.columns:
            md = col.meta_data
            names = list(md.path_in_schema)
            max_def = pf.schema.max_definition_level(names)
            max_rep = pf.schema.max_repetition_level(names)
            start = min(x for x in (md.data_page_offset, md.dictionary_page_offset) if x is not None)
            end = start + md.total_compressed_size
            previous = False
            while start < end:
                stream = NumpyIO(raw[start:end])
                h = ThriftObject.from_buffer(stream, 'PageHeader')
                body_start = start + stream.tell()
                body = raw[body_start:body_start + h.compressed_page_size]
                if len(body) != h.compressed_page_size:
                    raise ValueError('truncated page body')
                if h.type in (0, 3):
                    detail = h.data_page_header if h.type == 0 else h.data_page_header_v2
                    rec = dict(row_group=gi, path=names, page_version=1 if h.type == 0 else 2,
                               value_encoding=detail.encoding, codec=md.codec,
                               compressed_bytes=h.compressed_page_size,
                               decoded_bytes=h.uncompressed_page_size,
                               level_entries=detail.num_values, max_definition=max_def,
                               max_repetition=max_rep)
                    if h.type == 0:
                        body = bytes(decompress_data(body, h.uncompressed_page_size, md.codec))
                        pos = 0
                        streams = []
                        for maximum, encoding in ((max_rep, detail.repetition_level_encoding),
                                                  (max_def, detail.definition_level_encoding)):
                            if maximum:
                                if encoding != 3:
                                    raise ValueError('probe only decodes RLE level encoding')
                                size = int.from_bytes(body[pos:pos + 4], 'little'); pos += 4
                                streams.append(hybrid(body[pos:pos + size], maximum.bit_length(), detail.num_values))
                                pos += size
                            else:
                                streams.append([0] * detail.num_values)
                    else:
                        r = detail.repetition_levels_byte_length
                        d = detail.definition_levels_byte_length
                        streams = [hybrid(body[:r], max_rep.bit_length(), detail.num_values) if max_rep else [0] * detail.num_values,
                                   hybrid(body[r:r + d], max_def.bit_length(), detail.num_values) if max_def else [0] * detail.num_values]
                        rec.update(declared_rows=detail.num_rows, declared_nulls=detail.num_nulls)
                    reps, defs = streams
                    if any(x > max_rep for x in reps) or any(x > max_def for x in defs):
                        raise ValueError('level outside schema range')
                    rec.update(repetition_levels=reps, definition_levels=defs,
                               row_starts=reps.count(0), present_values=defs.count(max_def),
                               continues_previous_row=bool(reps and reps[0] and previous))
                    records.append(rec)
                    previous = True
                start = body_start + h.compressed_page_size
            if start != end:
                raise ValueError('chunk extent mismatch')
    return records


def schema_contract(schema):
    nodes = []
    def walk(field, parent):
        typ = field.type
        kind = 0 if pa.types.is_struct(typ) else 14 if pa.types.is_list(typ) else 13 if pa.types.is_fixed_size_binary(typ) else KINDS.get(str(typ))
        if kind is None:
            raise ValueError(f'unsupported type {typ}')
        idx = len(nodes) + 1
        nodes.append(dict(name=field.name, kind=kind, parent=parent,
                          nullable=field.nullable, fixed_width=typ.byte_width if kind == 13 else 0))
        if kind == 0:
            for child in typ:
                walk(child, idx)
        elif kind == 14:
            # Element wrapper spelling is not part of logical field identity.
            walk(pa.field('element', typ.value_type, nullable=typ.value_field.nullable), idx)
    for field in schema:
        walk(field, 0)
    return nodes


def canonical(value, typ):
    if value is None:
        return None
    if pa.types.is_struct(typ):
        return {field.name: canonical(value[field.name], field.type) for field in typ}
    if pa.types.is_list(typ):
        return [canonical(v, typ.value_type) for v in value]
    if pa.types.is_binary(typ) or pa.types.is_fixed_size_binary(typ):
        return 'x' + bytes(value).hex()
    if pa.types.is_floating(typ):
        return int.from_bytes(struct.pack('<f' if typ.bit_width == 32 else '<d', value), 'little')
    return int(value)


def read_native(binary, path, projection=None):
    args = [str(binary), str(path)]
    if projection:
        # CLI path components are separate arguments; multiple paths use --.
        for i, components in enumerate(projection):
            if i:
                args.append('--')
            args.extend(components)
    proc = subprocess.run(args, text=True, capture_output=True)
    if proc.returncode:
        raise RuntimeError(proc.stderr or proc.stdout)
    lines = iter(proc.stdout.splitlines())
    rows, count = map(int, next(lines).split())
    nodes, values = [], {}
    for idx in range(1, count + 1):
        name = bytes.fromhex(next(lines)).decode()
        kind, parent, nullable, width, size = map(int, next(lines).split())
        if kind == 14:
            name = name  # preserve LIST field name
        if parent and nodes[parent - 1]['kind'] == 14:
            name = 'element'
        nodes.append(dict(name=name, kind=kind, parent=parent, nullable=bool(nullable), fixed_width=width))
        if kind in (0, 14):
            vals = []
            for _ in range(size):
                line = list(map(int, next(lines).split()))
                vals.append(line)
            values[idx] = vals
        else:
            values[idx] = [None if (line := next(lines)) == 'null' else line if kind in (12, 13) else int(line) for _ in range(size)]
    def resolve(idx, row):
        node = nodes[idx - 1]
        val = values[idx][row]
        if node['kind'] not in (0, 14):
            return val
        if not val[0]:
            return None
        children = [i + 1 for i, n in enumerate(nodes) if n['parent'] == idx]
        if node['kind'] == 14:
            return [resolve(children[0], j) for j in range(val[1], val[2])]
        return {nodes[c - 1]['name']: resolve(c, row) for c in children}
    result = [{n['name']: resolve(i + 1, row) for i, n in enumerate(nodes) if n['parent'] == 0} for row in range(rows)]
    return nodes, result


def compare(path, binary=None, projection=None):
    table = pq.ParquetFile(path).read()
    schema = table.schema
    if projection:
        def selected(field, paths):
            if any(len(p) == 1 for p in paths):
                return field
            return pa.field(field.name, pa.struct([selected(c, [p[1:] for p in paths if p[1] == c.name]) for c in field.type if any(len(p) > 1 and p[1] == c.name for p in paths)]), nullable=field.nullable)
        schema = pa.schema([selected(f, [p for p in projection if p[0] == f.name]) for f in schema if any(p[0] == f.name for p in projection)])
    expected = [{f.name: canonical(row[f.name], f.type) for f in schema} for row in table.to_pylist()]
    result = dict(pyarrow='pass', rows=len(expected), schema=schema_contract(schema))
    if binary:
        nodes, actual = read_native(binary, path, projection)
        result['native'] = 'pass' if nodes == schema_contract(schema) and actual == expected else dict(status='mismatch', schema_matches=nodes == schema_contract(schema), first_row=next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b), None), actual_rows=len(actual))
    try:
        rel = duckdb.connect().execute('SELECT * FROM read_parquet(?, hive_partitioning=false)', [str(path)])
        duck_table = rel.to_arrow_table()
        cols = duck_table.column_names
        duck = [{f.name: canonical(row[f.name], f.type) for f in schema} for row in duck_table.to_pylist()]
        def compatible(actual, expected):
            if pa.types.is_struct(expected):
                return pa.types.is_struct(actual) and all(actual.get_field_index(f.name) >= 0 and compatible(actual.field(f.name).type,f.type) for f in expected)
            if pa.types.is_list(expected):
                return pa.types.is_list(actual) and compatible(actual.value_type,expected.value_type)
            if pa.types.is_fixed_size_binary(expected):
                return pa.types.is_binary(actual)
            return actual == expected
        type_ok = all(f.name in cols and compatible(duck_table.schema.field(f.name).type,f.type) for f in schema)
        result['duckdb'] = 'pass' if duck == expected and type_ok else dict(status='mismatch',values_match=duck == expected,types_match=type_ok)
        result['duckdb_schema'] = dict(actual=str(duck_table.schema), nullability='unavailable in SQL result metadata', fixed_binary_width='unavailable: DuckDB BLOB; byte values compared exactly')
    except Exception as error:
        result['duckdb'] = dict(status='reader_error', error=str(error))
    # Fastparquet flattens STRUCTs and loses parent validity. Never infer it
    # from child nullness. For representable flat/LIST values compare fully.
    script = "import sys,fastparquet; p=fastparquet.ParquetFile(sys.argv[1]); d=p.to_pandas(); print(d.columns.tolist())"
    fp = subprocess.run([sys.executable, '-c', script, str(path)], capture_output=True, text=True)
    if fp.returncode:
        result['fastparquet'] = dict(status='reader_error', returncode=fp.returncode, error=fp.stderr)
    elif any(pa.types.is_struct(f.type) for f in schema):
        result['fastparquet'] = dict(status='unsupported_representation', reason='STRUCT flattening cannot preserve parent validity; not a parity pass', output=fp.stdout)
    else:
        try:
            frame = fastparquet.ParquetFile(path).to_pandas()
            def fp_value(value, typ):
                if value is None or value is np.ma.masked or str(value) == '<NA>':
                    return None
                if pa.types.is_list(typ):
                    if isinstance(value, (float, np.floating)) and np.isnan(value):
                        return None
                    return [fp_value(v, typ.value_type) for v in value]
                return canonical(value, typ)
            actual = [{f.name:fp_value(frame[f.name].iloc[i], f.type) for f in schema} for i in range(len(frame))]
            mismatch = next((i for i,(a,b) in enumerate(zip(actual,expected)) if a != b), None)
            result['fastparquet'] = 'pass' if actual == expected else dict(status='value_mismatch', first_row=mismatch, expected=expected[mismatch] if mismatch is not None else None, actual=actual[mismatch] if mismatch is not None else None, actual_rows=len(actual))
        except Exception as error:
            result['fastparquet'] = dict(status='unsupported_representation', error=str(error))
    return result


def generate():
    OUT.mkdir(parents=True, exist_ok=True)
    element = pa.field('element', pa.int64(), nullable=True)
    schema = pa.schema([
        pa.field('s', pa.struct([pa.field('x', pa.int32()), pa.field('inner', pa.struct([pa.field('z', pa.float64())])),
                                pa.field('items', pa.list_(element)), pa.field('raw', pa.binary()), pa.field('fixed', pa.binary(3)), pa.field('flag', pa.bool_())])),
        pa.field('required', pa.struct([pa.field('x', pa.int32(), nullable=False)]), nullable=False),
        pa.field('required_list', pa.list_(pa.field('element', pa.int32(), nullable=False)), nullable=False),
        pa.field('literal.dot', pa.int32()),
    ])
    rows = []
    for i in range(1105):
        items = None if i % 7 == 0 else [] if i % 7 == 1 else [None] if i % 7 == 2 else [j if j % 3 else None for j in range(259 if i % 29 == 0 else i % 13)]
        s = None if i % 11 == 0 else dict(x=None if i % 3 == 0 else i * -7,
            inner=None if i % 5 == 0 else dict(z=None if i % 4 == 0 else [-0.0, float('nan'), 1.25, -12.5][i % 4]),
            items=items, raw=None if i % 3 == 0 else bytes([i % 256, 0, 255]),
            fixed=None if i % 5 == 0 else b'abc', flag=None if i % 3 == 0 else bool(i % 2))
        rows.append(dict(s=s, required=dict(x=i), required_list=list(range(i % 6)), **{'literal.dot':i}))
    report = dict(seed=92741, versions={m.__name__:m.__version__ for m in (pa, np, duckdb, fastparquet)}, fixtures=[])
    for version in ('1.0', '2.0'):
        for enc in ('PLAIN', 'DICTIONARY', 'DELTA_BINARY_PACKED'):
            table = pa.Table.from_pylist(rows, schema=schema)
            options = dict(compression='NONE', use_dictionary=enc == 'DICTIONARY', data_page_version=version,
                           data_page_size=512, write_batch_size=64, row_group_size=503)
            if enc == 'DELTA_BINARY_PACKED':
                options['column_encoding'] = {'s.x': enc, 's.items.list.element': enc, 'required.x': enc, 'required_list.list.element': enc, 'literal.dot': enc}
            path = OUT / f'nested-{version}-{enc}.parquet'
            pq.write_table(table, path, **options)
            pages = page_evidence(path)
            integer_paths = set(options.get('column_encoding', {}))
            if integer_paths:
                assert all(p['value_encoding'] == 5 for p in pages if '.'.join(p['path']) in integer_paths)
            report['fixtures'].append(dict(path=str(path.relative_to(ROOT)), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                schema=str(schema), writer_options=options, pages=pages, oracles=compare(path)))
    for label, data in [('empty', []), ('nullparent', [dict(s=None, required=dict(x=0), required_list=[], **{'literal.dot':None})] * 9)]:
        path = OUT / f'{label}.parquet'
        pq.write_table(pa.Table.from_pylist(data, schema=schema), path, compression='NONE', use_dictionary=False)
        report['fixtures'].append(dict(path=str(path.relative_to(ROOT)), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), schema=str(schema), pages=page_evidence(path), oracles=compare(path)))
    (OUT / 'evidence.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def codecs(binary=None):
    table = pq.ParquetFile(OUT/'nested-1.0-PLAIN.parquet').read()
    report = []
    for version in ('1.0','2.0'):
        for codec in ('SNAPPY','GZIP'):
            path = OUT/f'nested-{version}-{codec}.parquet'
            options = dict(compression=codec,use_dictionary=True,data_page_version=version,data_page_size=512,write_batch_size=64,row_group_size=503)
            pq.write_table(table,path,**options)
            report.append(dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),writer_options=options,pages=page_evidence(path),parity=compare(path,binary)))
    (OUT/'codec-parity.json').write_text(json.dumps(report,indent=2)+'\n')
    if binary:
        assert all(e['parity']['native']=='pass' for e in report)
    return report


def corpus():
    results = []
    for name in ('foo.parquet', 'datapage_v2.snappy.parquet', 'nested1.parquet'):
        matches = list((ROOT.parent / 'fastparquet/test-data').rglob(name))
        for path in matches:
            evidence = page_evidence(path)
            results.append(dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), pages=evidence))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'corpus-pages.json').write_text(json.dumps(results, indent=2) + '\n')
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--generate', action='store_true')
    parser.add_argument('--corpus', action='store_true')
    parser.add_argument('--codecs', action='store_true')
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--file', type=Path)
    parser.add_argument('--projection', help='JSON array of component-path arrays')
    args = parser.parse_args()
    if args.generate:
        report = generate()
        print('Generated', len(report['fixtures']), 'fixtures')
    if args.codecs:
        codecs(args.binary)
    if args.corpus:
        for entry in corpus():
            print(entry['path'], entry['sha256'], len(entry['pages']), 'data pages')
    if args.file:
        print(json.dumps(compare(args.file, args.binary, json.loads(args.projection) if args.projection else None), indent=2))
    elif args.binary and not args.codecs:
        report = []
        for entry in json.loads((OUT / 'evidence.json').read_text())['fixtures']:
            path = ROOT / entry['path']
            try:
                result = compare(path, args.binary)
            except Exception as error:
                result = {'native':'error', 'error':str(error)}
            report.append(dict(path=str(path), results=result))
            print(path.name, result.get('native'))
        (OUT / 'parity.json').write_text(json.dumps(report, indent=2) + '\n')
        assert all(e['results'].get('native') == 'pass' for e in report), 'Unexpected native fixture outcome'


if __name__ == '__main__':
    main()
