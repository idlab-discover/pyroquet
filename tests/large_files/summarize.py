"""Summarize accepted raw samples without discarding slow observations."""
import json,statistics
from pathlib import Path
B=Path('build/large-files');samples=json.load(open(B/'accepted-baseline/samples.json'));cases=json.load(open('benchmarks/large-files/manifest.json'))['cases'];out=[]
validation={c['case']:c for c in json.load(open(B/'validation/results.json'))['results']}
for c in cases:
 item=dict(case=c['case'],selected_compressed_bytes=c['selected_compressed_bytes'],output_budget_bytes=c['output_bytes'],engines={})
 for engine in ['pyroquet','arrow','duckdb']:
  rows=[x for x in samples if x['case']==c['case'] and x['engine']==engine and x['accepted']];ns=[n for x in rows for n in x['samples_ns']]
  if not ns:continue
  med=statistics.median(ns);rss=max(x['peak_rss_kib'] for x in rows)*1024
  item['engines'][engine]=dict(n=len(ns),median_ms=med/1e6,min_ms=min(ns)/1e6,max_ms=max(ns)/1e6,selected_input_MiB_s=c['selected_compressed_bytes']/(med/1e9)/(1<<20),output_MiB_s=validation[c['case']]['materialized_output_bytes']/(med/1e9)/(1<<20),materialized_output_bytes=validation[c['case']]['materialized_output_bytes'],peak_rss_bytes=rss,resident_to_budget_ratio=rss/c['output_bytes'],rchar_lower_bound_per_load=[x['io'].get('rchar',0)/2 for x in rows],samples_ns=ns)
 item['pyroquet_faster_rounds']={engine:sum(next(x for x in samples if x['case']==c['case'] and x['engine']=='pyroquet' and x['round']==r)['samples_ns'][0]<next(x for x in samples if x['case']==c['case'] and x['engine']==engine and x['round']==r)['samples_ns'][0] for r in range(6)) for engine in ['arrow','duckdb']}
 out.append(item)
(B/'summary.json').write_text(json.dumps(out,indent=2))
for c in out[:6]:print(c['case'],[(e,round(v['median_ms'],2),round(v['peak_rss_bytes']/(1<<20),1)) for e,v in c['engines'].items()])
