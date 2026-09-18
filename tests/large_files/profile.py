"""Serialized user-space profiling, preserving permission failures and fallback."""
import json,subprocess
from pathlib import Path
B=Path('build/large-files');P=Path('profiling/large-files');P.mkdir(exist_ok=True)
cases=json.load(open('benchmarks/large-files/manifest.json'))['cases'];results=[]
for name in ['nf-narrow','luflow-narrow','Repo dictionary/nulls']:
 c=next(x for x in cases if x['case']==name);slug=name.replace('/','-').replace(' ','-')
 load=['taskset','-c','0',str(B/'load'),c['path'],str(c['max_output_bytes']),('999' if name=='Repo dictionary/nulls' else '19' if name=='nf-narrow' else '9'),'-',*c['selected_names']]
 cmd=['perf','record','-e','cycles:u','-F','99','-g','--call-graph','dwarf','-o',str(P/(slug+'.perf.data')),'--',*load]
 with (P/(slug+'.perf.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 item=dict(case=name,perf_command=cmd,perf_returncode=p.returncode)
 if p.returncode==0:
  with (P/(slug+'.perf-report.txt')).open('w') as f:subprocess.run(['perf','report','--stdio','--percent-limit','0.5','-i',str(P/(slug+'.perf.data'))],stdout=f,stderr=subprocess.STDOUT)
 else:
  load[6]='0'
  cmd=['valgrind','--tool=callgrind','--cache-sim=no','--branch-sim=no','--callgrind-out-file='+str(P/(slug+'.callgrind')), *load[3:]]
  with (P/(slug+'.callgrind.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=300)
  item.update(callgrind_command=cmd,callgrind_returncode=p.returncode)
  if p.returncode==0:
   with (P/(slug+'.callgrind.txt')).open('w') as f:subprocess.run(['callgrind_annotate','--inclusive=no','--threshold=95',str(P/(slug+'.callgrind'))],stdout=f,stderr=subprocess.STDOUT)
 results.append(item);(P/'profiles.json').write_text(json.dumps(results,indent=2));print(name,item,flush=True)
