"""Focused exporter regressions. Run with pinned oracle Python after building exporter."""
import json
import os
from pathlib import Path
import tempfile
import unittest
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
from parity import export_native, compare_export

ROOT=Path(__file__).resolve().parents[2]
BINARY=Path(os.environ.get('PYROQUET_RELEASE_EXPORT',ROOT/'build/release-export'))

class ParityTests(unittest.TestCase):
    def setUp(self):
        if not BINARY.is_file(): self.fail(f'Build current tests/release/export.mojo first: {BINARY}')
        self.temporary=tempfile.TemporaryDirectory(dir=ROOT/'build')
        self.addCleanup(self.temporary.cleanup)
        self.directory=Path(self.temporary.name)

    def check_table(self, table):
        path=self.directory/'input.parquet'; out=self.directory/'export'
        pq.write_table(table,path,row_group_size=65537 if len(table)>100 else 2,data_page_version='1.0',compression='zstd')
        descriptor=export_native(path,BINARY,out,128*1024*1024)
        self.assertEqual(descriptor['rows'],len(table))
        self.assertGreater(descriptor['resources']['max_rss_kib'],0)
        report=compare_export(path,out)
        self.assertEqual(report['unexpected'],[],report)
        self.assertEqual(report['engines']['pyarrow']['status'],'pass')
        return path,out

    def test_nullable_mixed_and_corruption(self):
        schema=pa.schema([pa.field('x',pa.int32()),pa.field('items',pa.list_(pa.int32())),pa.field('s',pa.string()),pa.field('b',pa.binary()),pa.field('flag',pa.bool_())])
        table=pa.Table.from_pylist([dict(x=1,items=[1,None],s='hé',b=b'\0a',flag=True),dict(x=None,items=[],s=None,b=None,flag=None),dict(x=-3,items=None,s='',b=b'',flag=False)],schema=schema)
        path,out=self.check_table(table)
        file=out/'1.bin'; data=bytearray(file.read_bytes());data[1]^=1;file.write_bytes(data)
        report=compare_export(path,out)
        self.assertEqual(report['status'],'failed')
        self.assertEqual({x['engine'] for x in report['unexpected']},{'pyarrow','duckdb','fastparquet'})

    def test_float16_struct_and_fixed_bytes_limitations(self):
        half=pa.array(np.array([0x8000,0x7e01,1],dtype='uint16').view('float16'))
        structure=pa.array([{'x':1},None,{'x':None}],type=pa.struct([pa.field('x',pa.int32())]))
        table=pa.Table.from_arrays([half,structure,pa.array([b'a\0\0',None,b'xyz'],type=pa.binary(3))],names=['half','structure','fixed'])
        path,out=self.check_table(table)
        report=compare_export(path,out)
        self.assertTrue(any('FLOAT16' in x['reason'] for x in report['limitations']))
        self.assertTrue(any('parent validity' in x['reason'] for x in report['limitations']))

    def test_chunk_boundaries(self):
        values=np.arange(65539,dtype='int32')
        self.check_table(pa.table({'x':values}))

    def test_row_count_corruption(self):
        path=self.directory/'zero-column.parquet'; out=self.directory/'export'
        pq.write_table(pa.table({}),path)
        export_native(path,BINARY,out,128*1024*1024)
        descriptor=json.loads((out/'descriptor.json').read_text())
        descriptor['rows']+=1
        (out/'descriptor.json').write_text(json.dumps(descriptor))
        report=compare_export(path,out)
        self.assertEqual(report['status'],'failed')
        self.assertTrue(any(x['engine']=='native_metadata' for x in report['unexpected']))

    def test_empty(self):
        self.check_table(pa.table({'x':pa.array([],type=pa.int64()),'s':pa.array([],type=pa.string())}))

if __name__=='__main__':unittest.main()
