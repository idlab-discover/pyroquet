"""Serialized randomized full materializers, raw output, exact-PID monitoring."""
import argparse,hashlib,json,os,random,subprocess,time
from pathlib import Path
P=Path('benchmarks/large-files'); B=Path('build/large-files');py=str(Path('build/oracle-uv/bin/python').absolute())
parser=argparse.ArgumentParser();parser.add_argument('--rounds',type=int,default=6);parser.add_argument('--out',default='baseline');parser.add_argument('--engines',nargs='+',choices=['pyroquet','arrow','duckdb'],default=['pyroquet','arrow','duckdb']);parser.add_argument('--cases',nargs='*');parser.add_argument('--binary',default=str(B/'load'));parser.add_argument('--candidate',help='Optional paired candidate binary; same lifecycle and projections');a=parser.parse_args()
if a.rounds<1:parser.error('--rounds must be positive')
if a.candidate:a.engines.append('candidate')
cases=json.loads((P/'manifest.json').read_text())['cases'];out=B/a.out;out.mkdir(exist_ok=False);samples=[]
if a.cases and not set(a.cases)<=set(c['case'] for c in cases):parser.error('Unknown case name')
(out/'runner-at-launch.py').write_text(Path(__file__).read_text())
(out/'manifest-at-launch.json').write_text((P/'manifest.json').read_text())
def file_hash(path):
 with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
identity=dict(manifest_sha256=file_hash(P/'manifest.json'),runner_sha256=file_hash(__file__),oracle_sha256=file_hash('tests/large_files/oracle.py'),baseline_binary=str(Path(a.binary).absolute()),baseline_sha256=file_hash(a.binary),candidate_binary=a.candidate,candidate_sha256=file_hash(a.candidate) if a.candidate else None,versions=subprocess.check_output([py,'-c','import pyarrow,duckdb,fastparquet;print(pyarrow.__version__,duckdb.__version__,fastparquet.__version__)'],text=True).strip())
(out/'run-identity.json').write_text(json.dumps(identity,indent=2))
allowed=sorted(os.sched_getaffinity(0));cpu=allowed[0];os.sched_setaffinity(0,{allowed[min(1,len(allowed)-1)]})
def counters(path):
 try:return {x.split()[0].rstrip(':'):int(x.split()[1]) for x in Path(path).read_text().splitlines() if len(x.split())>=2 and x.split()[1].isdigit()}
 except OSError:return {}
def cpu_busy():
 line=next(x for x in Path('/proc/stat').read_text().splitlines() if x.startswith('cpu'+str(cpu)+' '));v=list(map(int,line.split()[1:]));return sum(v[i] for i in (0,1,2,5,6,7))/os.sysconf('SC_CLK_TCK')
def procs():
 d={}
 for p in Path('/proc').iterdir():
  if not p.name.isdigit():continue
  try:
   s=(p/'stat').read_text().rsplit(')',1)[1].split();d[int(p.name)]=(int(s[11])+int(s[12]),(p/'comm').read_text().strip())
  except (OSError,IndexError,ValueError):pass
 return d
seen=set()
for c in cases:
 if a.cases and c['case'] not in a.cases:continue
 if c['path'] not in seen:
  with open(c['path'],'rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==c['file_sha256']
  seen.add(c['path'])
(out/'host.json').write_text(json.dumps(dict(affinity=allowed,cpu=cpu,coordinator=list(os.sched_getaffinity(0)),lscpu=subprocess.check_output(['lscpu'],text=True),meminfo=Path('/proc/meminfo').read_text(),proc_namespace=str(Path('/proc/self/ns/pid').readlink()),visible_processes=procs(),seed=180926,cache='hash warmed file cache + untimed materialization; no eviction',lifecycle='construct/load/materialize/close; result destruction outside timer; fresh process each trial',threads=1,paired_candidate=bool(a.candidate)),indent=2))
rng=random.Random(180926)
for rd in range(a.rounds):
 order=[(i,e) for i,c in enumerate(cases) if not a.cases or c['case'] in a.cases for e in a.engines];rng.shuffle(order)
 if a.candidate:
  indices=list(dict.fromkeys(i for i,e in order));order=[]
  for ci in indices:
   engines=a.engines.copy();rng.shuffle(engines);order.extend((ci,e) for e in engines)
 for ci,engine in order:
  c=cases[ci]
  available=counters('/proc/meminfo').get('MemAvailable',0)*1024
  if available < 3*c.get('output_bytes',c['max_output_bytes'])+(2<<30):raise RuntimeError('Insufficient RAM for materializer plus staging: '+c['case'])
  stem=f'{rd}-{ci}-{engine}'
  base=[str(Path(a.candidate if engine=='candidate' else a.binary).absolute()),c['path'],str(c['max_output_bytes']),'1','-',*c['selected_names']] if engine in ('pyroquet','candidate') else [py,str(Path('tests/large_files/oracle.py')),engine,str(ci)]
  cmd=['taskset','-c',str(cpu),*base];env=os.environ.copy();env.update(OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MKL_NUM_THREADS='1')
  cpu0=cpu_busy();vm0=counters('/proc/vmstat');before=procs();beg=time.monotonic();rss=0;swap=0;io={};activity=[];last=beg
  with (out/(stem+'.stdout')).open('w') as stdout,(out/(stem+'.stderr')).open('w') as stderr:
   child=subprocess.Popen(cmd,stdout=stdout,stderr=stderr,env=env)
   while True:
    ended,wait_status,usage=os.wait4(child.pid,os.WNOHANG)
    if ended:
     child.returncode=os.waitstatus_to_exitcode(wait_status);break
    status=counters(f'/proc/{child.pid}/status');rss=max(rss,status.get('VmHWM',0));swap=max(swap,status.get('VmSwap',0));io=counters(f'/proc/{child.pid}/io') or io
    now=time.monotonic();current=procs()
    for pid,(ticks,name) in current.items():
     if pid in (child.pid,os.getpid()) or pid not in before:continue
     use=(ticks-before[pid][0])/os.sysconf('SC_CLK_TCK')/max(now-last,.001)
     if use>.15:activity.append(dict(pid=pid,comm=name,cpu=use))
    before=current;last=now;time.sleep(.05)
  vm1=counters('/proc/vmstat');raw=(out/(stem+'.stdout')).read_text();vals=[int(l.split()[1]) for l in raw.splitlines() if l.startswith('TIME ')];swapped=swap>0 or vm1.get('pswpout',0)>vm0.get('pswpout',0) or vm1.get('pswpin',0)>vm0.get('pswpin',0)
  foreign_cpu=max(0,cpu_busy()-cpu0-usage.ru_utime-usage.ru_stime)
  item=dict(pinned_cpu_unattributed_busy_s=foreign_cpu,child_cpu_s=usage.ru_utime+usage.ru_stime,round=rd,case=c['case'],engine=engine,cmd=cmd,child_pid=child.pid,returncode=child.returncode,samples_ns=vals,process_wall_s=time.monotonic()-beg,peak_rss_kib=usage.ru_maxrss,peak_rss_sampled_kib=rss,minor_faults=usage.ru_minflt,major_faults=usage.ru_majflt,peak_swap_kib=swap,io=io,swap_counters_before={k:vm0.get(k) for k in ['pswpin','pswpout']},swap_counters_after={k:vm1.get(k) for k in ['pswpin','pswpout']},interference=activity,accepted=child.returncode==0 and len(vals)==1 and not swapped and not activity and foreign_cpu<max(.1,.05*(time.monotonic()-beg)))
  samples.append(item);(out/'samples.json').write_text(json.dumps(samples,indent=2));print(rd,c['case'],engine,vals,'accepted',item['accepted'],flush=True)

if any(not x["accepted"] for x in samples):raise SystemExit(1)
