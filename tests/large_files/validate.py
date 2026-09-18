"""Complete, bounded comparisons. No simultaneous full oracle tables."""
import argparse,gc,hashlib,json,subprocess,sys
from pathlib import Path
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
import duckdb,fastparquet
P=Path('benchmarks/large-files'); B=Path('build/large-files');record=np.dtype([('valid','u1'),('bits','<u8')]);CHUNK=65536
parser=argparse.ArgumentParser();parser.add_argument('--binary',default=str(B/'load'));parser.add_argument('--out',default='validation');parser.add_argument('--cases',nargs='*');a=parser.parse_args();out=B/a.out;out.mkdir(exist_ok=False);results=[]
def file_hash(path):
 with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
(out/'identity.json').write_text(json.dumps(dict(binary=a.binary,binary_sha256=file_hash(a.binary),manifest_sha256=file_hash(P/'manifest.json'),validator_sha256=file_hash(__file__)),indent=2))
(out/'manifest.json').write_bytes((P/'manifest.json').read_bytes())
def canonical(x):
 if isinstance(x,pa.ChunkedArray):x=x.combine_chunks()
 valid=np.asarray(x.is_valid());v=x.fill_null(0).to_numpy(zero_copy_only=False)
 bits=v.view('uint32').astype('uint64') if pa.types.is_float32(x.type) else v.view('uint64') if pa.types.is_float64(x.type) else v.astype('uint64')
 r=np.empty(len(v),dtype=record);r['valid']=valid;r['bits']=bits;r['bits'][~valid]=0;return r
def compare(actual,col,offset,*,nan_payloads=True):
 expected=canonical(col);got=actual[offset:offset+len(col)]
 if not nan_payloads and pa.types.is_floating(col.type):
  nan=np.asarray(col.fill_null(0).is_nan());g=got.copy();dt='uint32' if pa.types.is_float32(col.type) else 'uint64';ft='float32' if dt=='uint32' else 'float64'
  assert np.array_equal(np.isnan(g['bits'].astype(dt).view(ft)) & (g['valid']!=0),nan)
  g['bits'][nan]=0;expected['bits'][nan]=0;got=g
 assert np.array_equal(got,expected),('mismatch',offset,len(col))
for c in json.loads((P/'manifest.json').read_text())['cases']:
 if a.cases and c['case'] not in a.cases:continue
 item=dict(case=c['case'],oracles={},status='running');results.append(item)
 def save():(out/'results.json').write_text(json.dumps(dict(versions=dict(pyarrow=pa.__version__,duckdb=duckdb.__version__,fastparquet=fastparquet.__version__),results=results),indent=2))
 save();dump=out/'dump';dump.mkdir(exist_ok=True)
 try:
  with open(c['path'],'rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==c['file_sha256']
  p=subprocess.run([a.binary,c['path'],str(c['max_output_bytes']),'0',str(dump),*c['selected_names']],capture_output=True,text=True)
  item['returncode']=p.returncode;(out/(str(len(results))+'.stdout')).write_text(p.stdout);(out/(str(len(results))+'.stderr')).write_text(p.stderr)
  if p.returncode:raise RuntimeError(p.stderr[-2000:])
  pf=pq.ParquetFile(c['path']);names=c['selected_names'];rows=pf.metadata.num_rows
  header=next(l for l in p.stdout.splitlines() if l.startswith('WARMUP ')).split();assert list(map(int,header[2:]))==[rows,len(names)]
  assert [l[5:] for l in p.stdout.splitlines() if l.startswith('NAME ')]==names
  meta=[l.split() for l in p.stdout.splitlines() if l.startswith('COLUMN ')];assert len(meta)==len(names)
  item['null_counts']={name:int(meta[i][4]) for i,name in enumerate(names)}
  widths={'int8':1,'uint8':1,'int16':2,'uint16':2,'int32':4,'uint32':4,'int64':8,'uint64':8,'float32':4,'float64':8}
  item['materialized_output_bytes']=sum(rows*widths[m[2]]+((rows+7)//8 if int(m[4]) else 0) for m in meta)
  actual=[np.memmap(dump/f'{i}.bin',dtype=record,mode='r',shape=(rows,)) for i in range(len(names))]
  item['dump_sha256']={}
  for i,name in enumerate(names):
   field=pf.schema_arrow.field(name);dtype={'float':'float32','double':'float64'}.get(str(field.type),str(field.type));assert meta[i][1:4]==[str(i),dtype,str(field.nullable)]
   assert (dump/f'{i}.bin').stat().st_size==rows*9
   offset=0;nulls=0
   for batch in pf.iter_batches(batch_size=CHUNK,columns=[name],use_threads=False):
    col=batch.column(0);compare(actual[i],col,offset);offset+=len(col);nulls+=col.null_count
   assert offset==rows and meta[i][4:]==[str(nulls),str(rows)]
   with (dump/f'{i}.bin').open('rb') as f:item['dump_sha256'][name]=hashlib.file_digest(f,'sha256').hexdigest()
  item['oracles']['pyarrow']='pass complete values, exact floating bits, nulls, order, types, nullability, counts';save()
  con=duckdb.connect();con.execute('SET threads=1');q='SELECT '+','.join('"'+n.replace('"','""')+'"' for n in names)+' FROM read_parquet(?)'
  stream=con.execute(q,[c['path']]).fetch_record_batch(CHUNK);assert stream.schema.names==names
  for f in stream.schema:assert f.type==pf.schema_arrow.field(f.name).type
  offset=0
  for batch in stream:
   for i,col in enumerate(batch.columns):compare(actual[i],col,offset,nan_payloads=False)
   offset+=batch.num_rows
  assert offset==rows;con.close();item['oracles']['duckdb']='pass complete values/types/nulls/order; NaN payloads excluded';save()
  fp=fastparquet.ParquetFile(c['path']);assert fp.count()==rows
  for gi,g in enumerate(fp.row_groups):
   assert g.num_rows==pf.metadata.row_group(gi).num_rows
   for ci,cc in enumerate(g.columns):
    for attr in ['num_values','data_page_offset','dictionary_page_offset','total_compressed_size','total_uncompressed_size']:assert getattr(cc.meta_data,attr)==getattr(pf.metadata.row_group(gi).column(ci),attr)
  item['oracles']['fastparquet_metadata']='pass rows/groups/chunk sizes/offsets'
  errors=[]
  for i,name in enumerate(names):
   try:
    frame=fp.to_pandas(columns=[name]);series=frame[name];field=pf.schema_arrow.field(name)
    dtype={'float':'float32','double':'float64'}.get(str(field.type),str(field.type));assert str(series.dtype).lower()==dtype
    for off in range(0,rows,CHUNK):
     got=actual[i][off:off+CHUNK];v=series.iloc[off:off+CHUNK]
     if pa.types.is_floating(field.type):
      vals=v.to_numpy();wanted=got['bits'].astype('uint32' if dtype=='float32' else 'uint64').view(dtype);valid=got['valid'].astype(bool)
      assert np.array_equal(np.isnan(vals),np.isnan(wanted)|~valid)
      assert np.array_equal(vals[valid].view('uint32' if dtype=='float32' else 'uint64'),wanted[valid].view('uint32' if dtype=='float32' else 'uint64'))
     else:compare(actual[i],pa.array(v,type=field.type,from_pandas=True),off)
    del frame,series;gc.collect()
   except Exception as e:errors.append(dict(column=name,error=repr(e)))
  item['oracles']['fastparquet']={'status':'failed' if errors else 'pass','errors':errors,'limitation':'floating NaN/null ambiguity; one full column per call because public API has row-group granularity'}
  known=json.loads(Path('tests/large_files/oracle_exceptions.json').read_text())
  expected=bool(errors) and all(any(k['file_sha256']==c['file_sha256'] and k['version']==fastparquet.__version__ and k['column']==e['column'] and k['error']==e['error'] for k in known) for e in errors)
  item['status']='validated' if not errors else 'validated_with_known_oracle_failure' if expected else 'failed_fastparquet'
  if expected:item['oracles']['fastparquet']['status']='known_failure_not_pass'
  del actual;gc.collect()
 except Exception as e:item.update(status='failed',error=repr(e))
 save();print(c['case'],item['status'],item.get('error',''),flush=True)
 for file in dump.glob('*.bin'):file.unlink()

if any(x['status'].startswith('failed') for x in results):raise SystemExit(1)
