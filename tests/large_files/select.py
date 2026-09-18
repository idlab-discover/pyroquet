import hashlib,json,math
from pathlib import Path
P=Path('benchmarks/large-files'); inv=json.loads((P/'inventory.json').read_text()); cases=[]; identities={}
width={'int8':1,'int16':2,'int32':4,'int64':8,'uint8':1,'uint16':2,'uint32':4,'uint64':8,'float':4,'double':8}
def add(f,id,cols):
 selected=[next(c for c in f['columns'] if c['name']==n) for n in cols]
 values=f['rows']*sum(width[c['arrow_type']] for c in selected); validity=sum((f['rows']+7)//8 for c in selected if c['nullable'])
 out=values+validity
 cases.append(dict(case=id,path=f['path'],file_sha256=identities[f['path']],whole_file_bytes=f['size'],mtime_ns=f['mtime_ns'],inode=f['inode'],origin='original',rows=f['rows'],row_groups=f['row_groups'],selected_names=cols,columns=selected,selected_compressed_bytes=sum(g['compressed'] for c in selected for g in c['chunks']),selected_uncompressed_page_bytes=sum(g['uncompressed'] for c in selected for g in c['chunks']),output_values_bytes=values,output_validity_bytes=validity,output_offsets_bytes=0,output_bytes=out,max_output_bytes=max(1<<30,math.ceil(out/(1<<30))*(1<<30)),memory_plan=dict(output_bytes=out,page_and_dictionary_reserve_bytes=2<<30,oracle_policy='sequential process; Arrow/DuckDB bounded validation batches; Fastparquet one column at a time',available_ram_bytes_at_planning=59<<30,swap_allowed=False),unsupported_exclusions=[dict(name=c['name'],type=c['arrow_type'],reason='unsupported logical type') for c in f['columns'] if c['arrow_type'] not in width]))
for family,short in [('ember-2017-v2-features','ember'),('nfuqnidsv2','nf'),('luflow','luflow')]:
 f=next(f for f in inv if '/'+family+'/' in f['path'] and (short!='ember' or '/train_' in f['path']));print('hash',short,flush=True)
 with open(f['path'],'rb') as stream:identities[f['path']]=hashlib.file_digest(stream,'sha256').hexdigest()
 supported=[c for c in f['columns'] if c['arrow_type'] in width]
 if short=='ember':
  order=sorted(supported,key=lambda c:sum(g['compressed'] for g in c['chunks']),reverse=True); wide=[];total=0
  for c in order:
   wide.append(c['name']);total+=sum(g['compressed'] for g in c['chunks'])
   if total>=1<<30:break
  narrow=wide[:2]
 elif short=='nf':narrow=['L4_SRC_PORT','Label'];wide=[c['name'] for c in supported[:16]]+['Label']
 else:narrow=['num_pkts_in','proto'];wide=[c['name'] for c in supported]
 add(f,short+'-narrow',narrow);add(f,short+'-wide',wide)
 # All-original-wide is recorded as an explicit scanner workload, not a timing claim.
 (P/(short+'-full-deferred.json')).write_text(json.dumps(dict(path=f['path'],status='materialization_measured_scanner_memory_bound_pending' if short=='luflow' else 'deferred_to_package_03',reason='full supported width exceeds default 1 GiB; LUFlow full numeric width already measured with explicit limit; scanner memory-bound coverage',supported_output_bytes=f['rows']*sum(width[c['arrow_type']] for c in supported)+sum((f['rows']+7)//8 for c in supported if c['nullable']),columns=[c['name'] for c in supported]),indent=2))
old=json.loads(Path('build/investigations/packed-dictionary-materialization/20260918-snappy010/cases.json').read_text())
for c in old:
 c.update(origin='retained_control',max_output_bytes=1<<30)
 import pyarrow.parquet as pq
 f=pq.ParquetFile(c['path']);c['whole_file_bytes']=Path(c['path']).stat().st_size;c['rows']=f.metadata.num_rows;c['row_groups']=f.metadata.num_row_groups
 c['selected_compressed_bytes']=sum(f.metadata.row_group(g).column(f.schema.names.index(n)).total_compressed_size for g in range(f.metadata.num_row_groups) for n in c['selected_names'])
 c['output_bytes']=c['rows']*sum(width[str(f.schema_arrow.field(n).type)] for n in c['selected_names'])+sum((c['rows']+7)//8 for n in c['selected_names'] if f.schema_arrow.field(n).nullable)
 cases.append(c)
(P/'manifest.json').write_text(json.dumps(dict(version=1,inventory='inventory.json',exclusions='excluded-ember-concat.json',cases=cases),indent=2))
for c in cases:print(c['case'],len(c['selected_names']),c.get('selected_compressed_bytes'),c.get('output_bytes'))
