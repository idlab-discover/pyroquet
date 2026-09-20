"""Portable deterministic release fixtures, emitted and inspected in bounded batches.

Development-only: use the pinned tests/oracle-requirements.txt environment.
Existing fixtures are accepted only after manifest, producer and full-hash checks.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import importlib.metadata
import json
from pathlib import Path
import struct
import time

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

SEED = 20260920
FORMAT_VERSION = 1
BATCH_ROWS = 65536
CODECS = {0: 'NONE', 1: 'snappy', 2: 'gzip', 6: 'zstd'}
PACKAGES = ('cramjam', 'duckdb', 'fastparquet', 'fsspec', 'numpy', 'packaging',
            'pandas', 'pyarrow', 'python-dateutil', 'pytz', 'six', 'thrift', 'tzdata')


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(4 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def identity() -> dict:
    return dict(format_version=FORMAT_VERSION, seed=SEED,
                versions={p: importlib.metadata.version(p) for p in PACKAGES},
                generator_sha256=sha256(Path(__file__)))


def options(codec: int, version: int, dictionary: bool, small=False) -> dict:
    return dict(compression=CODECS[codec], data_page_version=f'{version}.0',
                use_dictionary=dictionary, row_group_size=31 if small else BATCH_ROWS,
                data_page_size=128 if small else 1024 * 1024,
                write_batch_size=13 if small else 8192,
                dictionary_pagesize_limit=1024 if small else 1024 * 1024,
                write_statistics=True, version='2.6')


def _valid(mode, rows):
    if mode == 'allnull':
        return np.zeros(rows, dtype=bool)
    return np.arange(rows) % 7 != 0 if mode == 'nullable' else np.ones(rows, dtype=bool)


def _floating(dtype, patterns, rows, valid):
    unsigned = np.dtype(f'<u{dtype.bit_width // 8}')
    values = np.resize(np.asarray(patterns, dtype=unsigned), rows)
    return pa.Array.from_buffers(dtype, rows, [pa.py_buffer(np.packbits(valid, bitorder='little')),
                                               pa.py_buffer(values)], null_count=int((~valid).sum()))


def small_flat(mode: str) -> pa.Table:
    rows = 0 if mode == 'empty' else 97
    valid = _valid(mode, rows)
    nullable = mode != 'required'
    arrays, fields = [], []
    for dtype in (pa.bool_(), pa.int8(), pa.uint8(), pa.int16(), pa.uint16(),
                  pa.int32(), pa.uint32(), pa.int64(), pa.uint64()):
        if pa.types.is_boolean(dtype):
            values = np.arange(rows) % 2 == 0
        else:
            limits = np.iinfo(dtype.to_pandas_dtype())
            values = np.resize(np.asarray([0, 1, limits.min, limits.min + 1, limits.max - 1, limits.max],
                                          dtype=dtype.to_pandas_dtype()), rows)
        arrays.append(pa.array(values, mask=~valid, type=dtype))
        fields.append(pa.field(str(dtype), dtype, nullable))
    for dtype, patterns in (
        (pa.float16(), [0, 0x8000, 1, 0x3ff, 0x3c00, 0x7bff, 0x7c00, 0xfc00, 0x7e01, 0x7c01]),
        (pa.float32(), [0, 0x80000000, 1, 0x007fffff, 0x3f800000, 0x7f7fffff, 0x7f800000, 0xff800000, 0x7fc00001, 0x7f800001]),
        (pa.float64(), [0, 0x8000000000000000, 1, 0x000fffffffffffff, 0x3ff0000000000000,
                       0x7fefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000,
                       0x7ff8000000000001, 0x7ff0000000000001])):
        arrays.append(_floating(dtype, patterns, rows, valid))
        fields.append(pa.field(str(dtype), dtype, nullable))
    for name, dtype, pool in (
        ('text', pa.string(), ['', 'plain', 'a\0b', '中文', '😀', 'prefix' * 25]),
        ('raw', pa.binary(), [b'', b'\0', b'\xff\x80\0', bytes(range(256))]),
        ('fixed', pa.binary(2), [b'\0\0', b'\0\xff', b'\xff\0', b'ab'])):
        arrays.append(pa.array([pool[i % len(pool)] if valid[i] else None for i in range(rows)], type=dtype))
        fields.append(pa.field(name, dtype, nullable))
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields))


def small_nested(mode: str) -> pa.Table:
    rows = 0 if mode == 'empty' else 97
    nullable = mode != 'required'
    child = pa.field('element', pa.int32(), nullable)
    group = pa.struct([pa.field('number', pa.int32(), nullable), pa.field('text', pa.string(), nullable)])
    schema = pa.schema([pa.field('record', group, nullable), pa.field('items', pa.list_(child), nullable)])
    records, lists = [], []
    for i in range(rows):
        if mode == 'allnull' or (mode == 'nullable' and i % 7 == 0):
            records.append(None)
            lists.append(None)
        else:
            records.append({'number': None if nullable and i % 5 == 0 else i - 48,
                            'text': None if nullable and i % 3 == 0 else ('中文' if i % 2 else '')})
            lists.append([] if i % 4 == 0 else [i, None if nullable and i % 3 == 0 else -i])
    return pa.Table.from_arrays([pa.array(records, type=group), pa.array(lists, type=pa.list_(child))], schema=schema)


def _annotate_enum(path: Path):
    # Small fixtures only: replace STRING footer annotation, retaining page bytes.
    import fastparquet
    raw = path.read_bytes()
    metadata = fastparquet.ParquetFile(path).fmd
    leaf = metadata.schema[1]
    leaf.converted_type = 4
    leaf.logicalType = {4: {}}
    metadata.key_value_metadata = None
    footer = bytes(metadata.to_bytes())
    start = len(raw) - 8 - struct.unpack_from('<I', raw, len(raw) - 8)[0]
    path.write_bytes(raw[:start] + footer + struct.pack('<I', len(footer)) + b'PAR1')


def flat_batch(rng, rows):
    # Random 64-bit integers keep the disk size representative and reproducible.
    return pa.Table.from_arrays([pa.array(rng.integers(0, 2**64, rows, dtype=np.uint64))
                                 for _ in range(16)],
                                schema=pa.schema([pa.field(f'n{i}', pa.uint64(), False) for i in range(16)]))


def mixed_batch(rng, rows):
    # Buffers avoid Python per-row object growth even for the wide binary field.
    raw = rng.integers(0, 256, rows * 256, dtype=np.uint8)
    text = rng.integers(33, 127, rows * 64, dtype=np.uint8)
    binary = pa.Array.from_buffers(pa.binary(), rows, [None, pa.py_buffer(np.arange(rows + 1, dtype='<i4') * 256), pa.py_buffer(raw)])
    strings = pa.Array.from_buffers(pa.string(), rows, [None, pa.py_buffer(np.arange(rows + 1, dtype='<i4') * 64), pa.py_buffer(text)])
    integer = pa.array(rng.integers(0, 2**64, rows, dtype=np.uint64))
    children = pa.array(rng.integers(-(2**31), 2**31, rows * 2, dtype=np.int32))
    list_type = pa.list_(pa.field('element', pa.int32(), False))
    lists = pa.ListArray.from_arrays(pa.array(np.arange(rows + 1, dtype='<i4') * 2), children, type=list_type)
    schema = pa.schema([pa.field('raw', pa.binary(), False), pa.field('text', pa.string(), False),
                        pa.field('number', pa.uint64(), False), pa.field('items', list_type, False)])
    return pa.Table.from_arrays([binary, strings, integer, lists], schema=schema)


def _write_batches(path, shape, batches, codec, version):
    settings = options(codec, version, False)
    writer_settings = {k: v for k, v in settings.items() if k != 'row_group_size'}
    rng = np.random.Generator(np.random.PCG64(SEED + (1 if shape == 'mixed' else 0)))
    make = mixed_batch if shape == 'mixed' else flat_batch
    writer = None
    decoded = 0
    try:
        for _ in range(batches):
            table = make(rng, BATCH_ROWS)
            decoded += table.nbytes
            if writer is None:
                writer = pq.ParquetWriter(path, table.schema, **writer_settings)
            writer.write_table(table, row_group_size=BATCH_ROWS)
    finally:
        if writer is not None:
            writer.close()
    return settings, decoded


def page_evidence(path: Path) -> dict:
    """Scan page headers only, with at most 64 KiB staging per header.

    Column metadata's encodings list is not sufficient evidence of actual data
    page encoding. Seek past compressed bodies; never buffer full large files.
    """
    import fastparquet
    from fastparquet.cencoding import NumpyIO, ThriftObject
    file = fastparquet.ParquetFile(path)
    counts = Counter()
    body_bytes = decoded_bytes = pages = 0
    max_header_bytes = 65536
    with path.open('rb') as stream:
        for group in file.row_groups:
            for column in group.columns:
                md = column.meta_data
                if md.total_compressed_size == 0:
                    continue
                start = min(x for x in (md.data_page_offset, md.dictionary_page_offset) if x is not None and x >= 4)
                end = start + md.total_compressed_size
                while start < end:
                    stream.seek(start)
                    header_bytes = stream.read(min(max_header_bytes, end - start))
                    buffer = NumpyIO(header_bytes)
                    header = ThriftObject.from_buffer(buffer, 'PageHeader')
                    consumed = buffer.tell()
                    if consumed <= 0 or header.compressed_page_size < 0 or header.uncompressed_page_size < 0:
                        raise ValueError(f'Invalid page header: {path}:{start}')
                    next_page = start + consumed + header.compressed_page_size
                    if next_page > end:
                        raise ValueError(f'Page exceeds column chunk: {path}:{start}')
                    if header.type == 0:
                        encoding, version = header.data_page_header.encoding, 1
                    elif header.type == 3:
                        encoding, version = header.data_page_header_v2.encoding, 2
                    elif header.type == 2:
                        encoding, version = header.dictionary_page_header.encoding, 0
                    else:
                        raise ValueError(f'Unexpected generated page type {header.type}')
                    counts[(md.codec, header.type, version, encoding)] += 1
                    body_bytes += header.compressed_page_size
                    decoded_bytes += header.uncompressed_page_size
                    pages += 1
                    start = next_page
                if start != end:
                    raise ValueError(f'Page scan did not consume chunk: {path}')
    return dict(count=pages, header_staging_budget_bytes=max_header_bytes,
                compressed_body_bytes=body_bytes, decoded_body_bytes=decoded_bytes,
                encodings=[dict(codec=c, page_type=p, page_version=v, encoding=e, count=n)
                           for (c, p, v, e), n in sorted(counts.items())])


def describe(path, category, settings, decoded_bytes, shape=None, mode=None):
    file = pq.ParquetFile(path)
    metadata = file.metadata
    columns = []
    for i in range(metadata.num_columns):
        pieces = [metadata.row_group(g).column(i) for g in range(metadata.num_row_groups)]
        nulls = [p.statistics.null_count if p.statistics is not None and p.statistics.has_null_count else None for p in pieces]
        columns.append(dict(path=file.schema.column(i).path, physical_type=file.schema.column(i).physical_type,
                            logical_type=str(file.schema.column(i).logical_type),
                            compressed_bytes=sum(p.total_compressed_size for p in pieces),
                            decoded_page_bytes=sum(p.total_uncompressed_size for p in pieces),
                            value_count=sum(p.num_values for p in pieces),
                            null_count=sum(nulls) if all(n is not None for n in nulls) else None,
                            null_density=(sum(nulls) / sum(p.num_values for p in pieces)
                                          if all(n is not None for n in nulls) and sum(p.num_values for p in pieces) else 0.0)))
    return dict(path=path.name, category=category, shape=shape, mode=mode,
                rows=metadata.num_rows, bytes=path.stat().st_size, sha256=sha256(path),
                schema=str(file.schema_arrow), physical_schema=str(file.schema).split('\n', 1)[1],
                seed=SEED + (1 if shape == 'mixed' else 0),
                row_groups=metadata.num_row_groups, columns=columns,
                selected_compressed_bytes=sum(c['compressed_bytes'] for c in columns),
                decoded_value_bytes=decoded_bytes, decoded_budget_bytes=4 * 2**30,
                generator_batch_rows=BATCH_ROWS, generator_working_budget_bytes=256 * 2**20,
                options=dict(settings, codec=next(k for k, v in CODECS.items() if v == settings['compression']),
                             page_version=int(settings['data_page_version'][0])), pages=page_evidence(path))


def generate(out: Path, large: bool = False) -> dict:
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    stamp = identity()
    manifest_path = out / 'manifest.json'
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        if any(manifest.get(k) != v for k, v in stamp.items()) or manifest.get('large') != large:
            raise ValueError(f'Stale fixture manifest: use a new output directory: {out}')
        expected = {record['path'] for record in manifest['files']}
        if {p.name for p in out.glob('*.parquet')} != expected:
            raise ValueError(f'Fixture file set changed: {out}')
        for record in manifest['files']:
            path = out / record['path']
            if path.stat().st_size != record['bytes'] or sha256(path) != record['sha256']:
                raise ValueError(f'Fixture identity mismatch: {path}')
        return manifest
    if any(out.iterdir()):
        raise ValueError(f'Partial or unrecognized fixture directory; use a new output directory: {out}')
    start = time.monotonic()
    records = []
    for version in (1, 2):
        for codec in CODECS:
            for dictionary in (False, True):
                for mode in ('required', 'nullable', 'empty', 'allnull'):
                    settings = options(codec, version, dictionary, small=True)
                    for shape, table in (('flat', small_flat(mode)), ('nested', small_nested(mode))):
                        path = out / f'small-{shape}-v{version}-c{codec}-d{int(dictionary)}-{mode}.parquet'
                        pq.write_table(table, path, **settings)
                        records.append(describe(path, 'small', settings, table.nbytes, shape, mode))
                    flat = small_flat(mode)
                    table = flat.select(['text']).rename_columns(['label'])
                    path = out / f'small-enum-v{version}-c{codec}-d{int(dictionary)}-{mode}.parquet'
                    pq.write_table(table, path, **settings)
                    _annotate_enum(path)
                    records.append(describe(path, 'small', settings, table.nbytes, 'enum', mode))
    workloads = [('medium', 'flat', 8, 0, 1), ('medium', 'mixed', 3, 1, 2)]
    if large:
        workloads += [('large', 'flat', 144, 0, 1), ('large', 'mixed', 60, 6, 2)]
    for category, shape, batches, codec, version in workloads:
        path = out / f'{category}-{shape}-v{version}-c{codec}.parquet'
        settings, decoded = _write_batches(path, shape, batches, codec, version)
        record = describe(path, category, settings, decoded, shape, 'required')
        if category == 'medium' and not 50 * 2**20 <= record['bytes'] <= 100 * 2**20:
            raise ValueError(f'Medium file outside 50–100 MiB contract: {record}')
        if category == 'large' and record['bytes'] <= 2**30:
            raise ValueError(f'Large file must exceed 1 GiB on disk: {record}')
        records.append(record)
    manifest = dict(**stamp, large=large, files=records,
                    generation_seconds=time.monotonic() - start,
                    exhaustive_float16='tests/float16_fixture_oracle.py + tests/test_float16.mojo',
                    selected_columns='all physical leaves',
                    notes=['Statistics null counts count leaf level entries for nested columns.',
                           'ENUM fixtures replace only schema annotations on Arrow STRING page bytes.',
                           'Allocation budgets are explicit limits; actual peak RSS is recorded by the release runner.'])
    temp = out / 'manifest.json.tmp'
    temp.write_text(json.dumps(manifest, indent=2) + '\n')
    temp.replace(manifest_path)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=Path('build/release-fixtures'))
    parser.add_argument('--large', action='store_true')
    args = parser.parse_args()
    result = generate(args.out, args.large)
    print(json.dumps(dict(files=len(result['files']), bytes=sum(f['bytes'] for f in result['files']),
                          manifest=str(args.out / 'manifest.json'))))
