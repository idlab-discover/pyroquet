"""Preserve and compare every instrumented output byte to validated baseline exports."""
import hashlib,json,subprocess,collections
from pathlib import Path
B=Path('build/large-files');P=Path('profiling/large-files');V=B/'validation';out=[]
manifest=json.load(open('benchmarks/large-files/manifest.json'))['cases'];validated=json.load(open(V/'results.json'))['results'];dump=B/'profile-dump';dump.mkdir(exist_ok=True)
for name in ['ember-wide','nf-wide','luflow-wide','Repo dictionary/nulls']:
 c=next(x for x in manifest if x['case']==name);vi=next(i for i,x in enumerate(validated) if x['case']==name);reference=validated[vi];known=json.loads(Path('tests/large_files/oracle_exceptions.json').read_text())
 errors=reference['oracles']['fastparquet'].get('errors',[])
 expected=bool(errors) and all(any(k['file_sha256']==c['file_sha256'] and k['column']==e['column'] and k['error']==e['error'] for k in known) for e in errors)
 assert reference['status']=='validated' or (reference['status'] in ('failed_fastparquet','validated_with_known_oracle_failure') and expected)
 slug=name.replace('/','-').replace(' ','-');log=P/(slug+'.phases.txt');cmd=['taskset','-c','0',str(B/'profile-load'),c['path'],str(c['max_output_bytes']),'0',str(dump),*c['selected_names']]
 with log.open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 item=dict(case=name,command=cmd,returncode=p.returncode);assert p.returncode==0,log
 meta=lambda text:[l for l in text.splitlines() if l.startswith(('COLUMN ','NAME '))]
 assert meta(log.read_text())==meta((V/(str(vi+1)+'.stdout')).read_text())
 for i,col in enumerate(c['selected_names']):
  path=dump/f'{i}.bin'
  with path.open('rb') as f:actual=hashlib.file_digest(f,'sha256').hexdigest()
  assert actual==reference['dump_sha256'][col],(name,col);path.unlink()
 totals=collections.Counter();pages=collections.Counter();nulls=0
 for l in log.read_text().splitlines():
  if not l.startswith('PHASE '):continue
  x=l.split();kind=x[1];v=list(map(int,x[2:]))
  if kind=='page':totals['levels']+=v[1];totals['values_ids_gather_scatter']+=v[2];nulls+=v[3];pages[v[4]]+=1
  elif kind=='allocation':totals['allocation_values']+=v[0];totals['allocation_validity']+=v[1]
  else:totals[kind]+=v[0]
 item.update(status='pass complete binary export and metadata identity',phase_ns=dict(totals),encoding_page_counts=dict(pages),decoded_nulls=nulls,load_ns=int(next(l for l in log.read_text().splitlines() if l.startswith('WARMUP ')).split()[1]))
 out.append(item);(P/'phase-summary.json').write_text(json.dumps(out,indent=2));print(name,dict(totals),flush=True)
