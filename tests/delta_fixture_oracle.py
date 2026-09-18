"""Generate independent delta fixtures and compare complete native integer output.

Run with build/oracle-uv/bin/python; requires a rebuilt tests/read_numeric.mojo
binary at build/read-numeric-delta. Page evidence comes from actual Thrift headers.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import duckdb
import fastparquet
from fastparquet.cencoding import NumpyIO, ThriftObject
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/delta-fixtures'


def pages(path):
    pf = fastparquet.ParquetFile(path)
    raw = path.read_bytes()
    evidence = []
    for gi, group in enumerate(pf.row_groups):
        for col in group.columns:
            md = col.meta_data
            start = md.data_page_offset
            end = start + md.total_compressed_size
            while start < end:
                stream = NumpyIO(raw[start:end])
                header = ThriftObject.from_buffer(stream, 'PageHeader')
                data = header.data_page_header or header.data_page_header_v2
                if header.type not in (0, 3) or data.encoding != 5:
                    raise AssertionError('Producer did not emit requested delta data pages')
                evidence.append(dict(row_group=gi, path=md.path_in_schema,
                    page_version=1 if header.type == 0 else 2,
                    value_encoding=data.encoding, codec=md.codec,
                    compressed_bytes=header.compressed_page_size,
                    decoded_bytes=header.uncompressed_page_size,
                    level_entries=data.num_values))
                start += stream.tell() + header.compressed_page_size
            assert start == end
    return evidence


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(seed=92741, versions={m.__name__: m.__version__ for m in
        (pa, fastparquet, duckdb, np)}, fixtures=[])
    rng = np.random.default_rng(report['seed'])
    for bits in (32, 64):
        info = np.iinfo(f'int{bits}')
        patterns = [0, 0, 1, -1, info.min, info.max, -100, 100]
        values = [int(patterns[i % len(patterns)]) if i < 257 else int(rng.integers(-1000000, 1000000)) for i in range(2065)]
        nullable = [None if i % 11 == 0 else x for i, x in enumerate(values)]
        for version in ('1.0', '2.0'):
            for null_mode, data in [('required', values), ('optional', nullable), ('allnull', [None] * len(values))]:
                schema = pa.schema([pa.field('x', pa.int32() if bits == 32 else pa.int64(), nullable=null_mode != 'required')])
                table = pa.Table.from_arrays([pa.array(data, type=schema.field(0).type)], schema=schema)
                name = f'int{bits}-{version}-{null_mode}.parquet'
                path = OUT / name
                options = dict(compression='NONE', use_dictionary=False, column_encoding='DELTA_BINARY_PACKED',
                    data_page_version=version, data_page_size=256, write_batch_size=128, row_group_size=1030)
                pq.write_table(table, path, **options)
                entry = dict(path=str(path.relative_to(ROOT)), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                    schema=str(schema), writer_options=options, rows=len(data),
                    nulls=sum(x is None for x in data), pages=pages(path), oracles={})
                assert pq.read_table(path).column('x').to_pylist() == data
                entry['oracles']['pyarrow'] = 'pass'
                assert [r[0] for r in duckdb.connect().execute('SELECT x FROM read_parquet(?)', [str(path)]).fetchall()] == data
                entry['oracles']['duckdb'] = 'pass'
                fp = subprocess.run([sys.executable, '-c',
                    "import json, sys, pandas as pd, fastparquet; "
                    "frame=fastparquet.ParquetFile(sys.argv[1]).to_pandas(); "
                    "print(json.dumps([None if pd.isna(x) else int(x) for x in frame.x]))",
                    str(path)], capture_output=True, text=True)
                if fp.returncode:
                    entry['oracles']['fastparquet'] = dict(status='reader_error', returncode=fp.returncode, error=fp.stderr)
                else:
                    actual = json.loads(fp.stdout)
                    mismatch = next((i for i, (x, y) in enumerate(zip(actual, data)) if x != y), None)
                    if len(actual) != len(data) or mismatch is not None:
                        entry['oracles']['fastparquet'] = dict(status='value_mismatch', actual_count=len(actual), first_mismatch=mismatch,
                            expected=data[mismatch] if mismatch is not None else None, actual=actual[mismatch] if mismatch is not None else None)
                    else:
                        entry['oracles']['fastparquet'] = 'pass'
                result = subprocess.run([str(ROOT / 'build/read-numeric-delta'), f'int{bits}', str(path), 'x'], capture_output=True, text=True)
                if result.returncode:
                    raise AssertionError(f'{name}: {result.stderr}')
                lines = result.stdout.splitlines()
                assert tuple(map(int, lines[0].split())) == (len(data), sum(x is None for x in data))
                assert [None if x == 'null' else int(x) for x in lines[1:]] == data
                entry['native'] = 'pass'
                report['fixtures'].append(entry)
                print(name, entry['oracles'])
    (OUT / 'evidence.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
