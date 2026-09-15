"""Inventory a local Fastparquet corpus; write metadata, not decoded values.

Run: build/validation-env/bin/python tests/inventory_fastparquet.py
"""
import collections
import json
from pathlib import Path
import subprocess

import fastparquet
from fastparquet.cencoding import NumpyIO, ThriftObject

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT.parent / 'fastparquet'
OUTPUT = ROOT / 'docs/private/fastparquet-corpus-inventory.json'


def enum_name(enum, value):
    return enum._VALUES_TO_NAMES.get(value, f'UNKNOWN_{value}')


def inventory(path):
    blob = path.read_bytes()
    result = {'path': str(path.relative_to(CORPUS)), 'size': len(blob)}
    if blob[:4] != b'PAR1':
        return result | {'parquet_magic': False}
    result['parquet_magic'] = True
    pf = fastparquet.ParquetFile(path)
    tt = fastparquet.parquet_thrift
    columns = [c for rg in pf.row_groups for c in rg.columns]
    result.update(
        rows=pf.count(), row_groups=len(pf.row_groups),
        footer_num_rows=pf.fmd.num_rows,
        row_group_rows=[group.num_rows for group in pf.row_groups],
        row_counts_consistent=pf.fmd.num_rows == sum(group.num_rows for group in pf.row_groups),
        writer=str(pf.fmd.created_by),
        types=sorted({enum_name(tt.Type, s.type) for s in pf.fmd.schema if s.type is not None}),
        converted=sorted({enum_name(tt.ConvertedType, s.converted_type) for s in pf.fmd.schema if s.converted_type is not None}),
        logical=[{'name':s.name, 'annotation':str(s.logicalType)} for s in pf.fmd.schema if s.logicalType is not None],
        repetitions=sorted({enum_name(tt.FieldRepetitionType, s.repetition_type) for s in pf.fmd.schema if s.repetition_type is not None}),
        codecs=sorted({enum_name(tt.CompressionCodec, c.meta_data.codec) for c in columns}),
        encodings=sorted({enum_name(tt.Encoding,e) for c in columns for e in c.meta_data.encodings}),
        column_indexes=sum(c.column_index_offset is not None for c in columns),
        offset_indexes=sum(c.offset_index_offset is not None for c in columns),
        bloom_filters=sum(c.meta_data.bloom_filter_offset is not None for c in columns),
    )
    pages = collections.Counter()
    checksums = 0
    errors = []
    for c in columns:
        if c.file_path:
            continue  # Summary metadata refers to pages in other files.
        md = c.meta_data
        start = min(x for x in [md.dictionary_page_offset, md.data_page_offset] if x is not None)
        end = start + md.total_compressed_size
        stream = NumpyIO(blob)
        stream.seek(start)
        try:
            while stream.tell() < end:
                header = ThriftObject.from_buffer(stream, 'PageHeader')
                pages[enum_name(tt.PageType, header.type)] += 1
                checksums += header.crc is not None
                stream.seek(header.compressed_page_size, 1)
            if stream.tell() != end:
                errors.append('page scan ended past column boundary')
        except Exception as exc:
            errors.append(str(exc))
    result.update(pages=dict(pages), page_checksums=checksums, page_scan_errors=errors)
    return result


def main():
    names = subprocess.check_output(['git','-C',str(CORPUS),'ls-files','-z','test-data'], text=True).split('\0')
    rows = [inventory(CORPUS / name) for name in names if name]
    summary = {'files':len(rows), 'parquet_files':sum(x['parquet_magic'] for x in rows), 'bytes':sum(x['size'] for x in rows if x['parquet_magic'])}
    for key in ['types','converted','codecs','encodings','repetitions']:
        summary[key] = dict(collections.Counter(v for row in rows for v in row.get(key,[])))
    for key in ['column_indexes','offset_indexes','bloom_filters','page_checksums']:
        summary[key] = sum(row.get(key,0) for row in rows)
    summary['page_types_by_file'] = dict(collections.Counter(v for row in rows for v in row.get('pages',{})))
    output = {'fastparquet_revision':subprocess.check_output(['git','-C',str(CORPUS),'rev-parse','HEAD'],text=True).strip(), 'reader_version':fastparquet.__version__, 'summary':summary, 'files':rows}
    OUTPUT.parent.mkdir(parents=True,exist_ok=True)
    OUTPUT.write_text(json.dumps(output,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
    print('Page scan errors:',[(x['path'],x['page_scan_errors']) for x in rows if x.get('page_scan_errors')])


if __name__ == '__main__':
    main()
