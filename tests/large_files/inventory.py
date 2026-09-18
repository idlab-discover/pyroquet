"""Read-only stat/footer inventory; no page-level encoding inference."""
import json
from pathlib import Path
import pyarrow.parquet as pq
ROOT=Path('/home/strgenix/postdoc/kaggle/datasets/sources/kaggle/dhoogla')
out=[]
for p in sorted(ROOT.rglob('*.parquet')):
 s=p.stat(); d=dict(path=str(p),size=s.st_size,mtime_ns=s.st_mtime_ns,inode=s.st_ino)
 try:
  f=pq.ParquetFile(p); m=f.metadata; arrow_schema=f.schema_arrow
  d.update(rows=m.num_rows,row_groups=m.num_row_groups,footer_bytes=m.serialized_size,columns=[])
  for i in range(m.num_columns):
   c=f.schema.column(i)
   d['columns'].append(dict(name=c.name,physical=c.physical_type,logical=str(c.logical_type),arrow_type=str(arrow_schema.field(i).type),nullable=c.max_definition_level>0,repetition=c.max_repetition_level,chunks=[dict(rows=m.row_group(g).num_rows,compressed=m.row_group(g).column(i).total_compressed_size,uncompressed=m.row_group(g).column(i).total_uncompressed_size,codec=m.row_group(g).column(i).compression,encodings=m.row_group(g).column(i).encodings,null_count=(m.row_group(g).column(i).statistics.null_count if m.row_group(g).column(i).statistics is not None else None),column_index=m.row_group(g).column(i).has_column_index,offset_index=m.row_group(g).column(i).has_offset_index) for g in range(m.num_row_groups)],page_encoding_frequency=None))
  d['status']='footer_valid'
 except Exception as e:d.update(status='unreadable',error=repr(e))
 out.append(d)
Path('benchmarks/large-files/inventory.json').write_text(json.dumps(out,indent=2))
print('files',len(out),'unreadable',[(x['path'],x['error']) for x in out if x['status']=='unreadable'])
for x in sorted(out,key=lambda x:x['size'],reverse=True)[:12]:
 print(x['size'],x['path'],x.get('rows'),len(x.get('columns',[])))
 if x.get('columns') and len(x['columns'])<50:print([(c['name'],c['arrow_type']) for c in x['columns']])
