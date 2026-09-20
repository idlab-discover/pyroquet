"""Check direct NuMojo UInt32 loads against three independent readers."""
from pathlib import Path
import subprocess
import json
import fastparquet
import pyarrow as pa
import pyarrow.parquet as pq
import duckdb
from check_pages import synthetic, header_fields, thrift_bytes, T
from check_metadata import fields, parts, put, encode
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/numojo-checks'; BINARY=OUT/'read'
FP_FAILURES=[]

def probe(p,name='value',budget=None):
    args=[str(BINARY),'uint32',str(p),name]
    if budget is not None:args.append(str(budget))
    return subprocess.run(args,text=True,capture_output=True)

def compare(p, name='value'):
    expected=pq.read_table(p,columns=[name])[name].to_pylist()
    import pandas as pd
    try:
        fp=fastparquet.ParquetFile(p).to_pandas(columns=[name])[name]
    except IndexError as error:
        # Installed fastparquet has a V2 multipage null-mask slicing defect.
        # Do not change fixtures or suppress other failures; Arrow and DuckDB
        # still independently check every value in these files.
        if not p.name.startswith('2.0-') or 'boolean index' not in str(error):raise
        FP_FAILURES.append({'path':str(p),'error':str(error)})
    else:
        assert [None if pd.isna(v) else int(v) for v in fp]==expected
    db=duckdb.connect()
    # Column names below are fixture-controlled, not interpolated user input.
    assert [r[0] for r in db.execute('SELECT "'+name+'" FROM read_parquet(?)',[str(p)]).fetchall()]==expected
    db.close()
    r=probe(p,name);assert r.returncode==0,(p,r.stdout,r.stderr)
    lines=r.stdout.splitlines()
    assert lines[0]==f'{len(expected)} {expected.count(None)}'
    assert [None if x=='null' else int(x) for x in lines[1:]]==expected,p
    return len(expected)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    subprocess.run(['pixi','run','mojo','build','-O3','-D','ASSERT=all','-I','src','-I','../NuMojo','tests/read_numeric.mojo','-o',str(BINARY)],cwd=ROOT,check=True)
    paths=list((ROOT/'build/fixtures/uint32').glob('*.parquet'));assert len(paths)==9
    # Fastparquet writer.py appends 8 zero bytes to V1 bodies. Parquet README
    # forbids page padding. Keep these fixtures unchanged as explicit rejections.
    padded=[p for p in paths if p.name in ('extrema.parquet','all_null.parquet')]
    for p in padded:
        r=probe(p)
        assert r.returncode!=0 and 'PLAIN byte length' in r.stdout+r.stderr
    paths=[p for p in paths if p not in padded]
    patterns={
      'mixed':[None if i%7==0 else (i*1234567)%2**32 for i in range(4099)],
      'all-null':[None]*1031,
      'all-valid':[0,2**31-1,2**31,2**32-1]*260,
      'runs':[None]*129+[2**32-1]*129+[None]*131+[0]*137,
      'empty':[],
    }
    for version in ('1.0','2.0'):
      for name,vs in patterns.items():
       for nullable in (True,False):
        if not nullable and any(v is None for v in vs):continue
        schema=pa.schema([pa.field('value',pa.uint32(),nullable=nullable),pa.field('ignored',pa.string())])
        table=pa.Table.from_arrays([pa.array(vs,pa.uint32()),pa.array(['x']*len(vs),pa.string())],schema=schema)
        p=OUT/f'{version}-{name}-{nullable}.parquet'
        pq.write_table(table,p,compression='NONE',use_dictionary=False,data_page_version=version,
                       data_page_size=128,write_batch_size=31,row_group_size=257)
        paths.append(p)
    count=sum(compare(p) for p in paths)
    # Literal dotted field names are not nested paths.
    p=OUT/'dotted.parquet';pq.write_table(pa.table({'a.b':pa.array([0,None,2**32-1],pa.uint32())}),p,compression='NONE',use_dictionary=False)
    count+=compare(p,'a.b')
    p=OUT/'compressed.parquet'
    pq.write_table(pa.table({'value':pa.array([1],pa.uint32())}),p,compression='snappy',use_dictionary=False)
    count+=compare(p)
    p=OUT/'dictionary.parquet'
    pq.write_table(pa.table({'value':pa.array([1,None,1,2**32-1],pa.uint32())}),p,compression='NONE',use_dictionary=True)
    count+=compare(p)
    p=OUT/'gzip.parquet'
    pq.write_table(pa.table({'value':pa.array([1],pa.uint32())}),p,compression='gzip',use_dictionary=False)
    count+=compare(p)
    for name,kwargs,table in [
      ('signed',{'compression':'NONE','use_dictionary':False},pa.table({'value':pa.array([1],pa.int32())})),
      ('nested',{'compression':'NONE','use_dictionary':False},pa.table({'value':pa.array([[1]],pa.list_(pa.uint32()))})),
    ]:
      p=OUT/(name+'.parquet');pq.write_table(table,p,**kwargs)
      assert probe(p).returncode!=0,name
    p=OUT/'1.0-all-valid-False.parquet'
    assert probe(p,'missing').returncode!=0
    assert probe(p,budget=0).returncode!=0
    assert probe(p,budget=-1).returncode!=0
    # Genuine body corruption, with structurally consistent header/footer lengths.
    def bad_body(name,body,nullable=True):
      h=header_fields(0,len(body));data=thrift_bytes(h)+body
      f=fields();s,g,c,m=parts(f)
      if not nullable:put(s[1],(3,T.I32,0))
      put(m,(6,T.I64,len(data)));put(m,(7,T.I64,len(data)));put(g,(2,T.I64,len(data)))
      p=OUT/(name+'.parquet');p.write_bytes(encode(f,payload=data))
      r=probe(p,'x');assert r.returncode!=0,(name,r.stdout)
    for name,body in [
      ('truncated-level-length',b'\0'),
      ('levels-outside',b'\xff'*4),
      ('zero-run',b'\x01\0\0\0\0'),
      ('invalid-level',b'\x02\0\0\0\x06\x02'),
      ('too-many-levels',b'\x02\0\0\0\x08\x01'),
      ('trailing-levels',b'\x03\0\0\0\x06\x00\x00'),
      ('missing-values',b'\x02\0\0\0\x06\x01'),
      ('extra-values',b'\x02\0\0\0\x06\x00'+b'\0'*4),
    ]:bad_body(name,body)
    bad_body('required-truncated',b'\0'*11,False)
    (OUT/'oracle-limitations.json').write_text(json.dumps(FP_FAILURES,indent=2))
    print(f'Matched {count} values/nulls across {len(paths)+4} files against PyArrow and DuckDB; fastparquet matched {len(paths)+4-len(FP_FAILURES)}, with {len(FP_FAILURES)} documented V2 oracle failures. Rejected 14 unsupported/malformed/budget cases and 2 padded fastparquet fixtures.')
if __name__=='__main__':main()
