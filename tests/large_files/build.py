"""Freeze imported source and isolate compiler imports from installed mojoc."""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
R=Path.cwd();parser=argparse.ArgumentParser();parser.add_argument('--out',default='build/large-files');args=parser.parse_args();B=(R/args.out).resolve(); H=R/'build/investigations/packed-dictionary-materialization/20260918-snappy010'
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def git(p,*a):return subprocess.check_output(['git','-C',str(p),*a],text=True).strip()
if (B/'accepted-baseline').exists():raise SystemExit('Accepted baseline is immutable; use --out for a new build cohort')
B.mkdir(exist_ok=True,parents=True)
for source,dest in [(R/'src',B/'source/src'),(H/'codec',B/'codec'),(H/'numojo',B/'numojo'),(H/'stdlib',B/'stdlib')]:
 if not dest.exists():shutil.copytree(source,dest,symlinks=True)
 elif source==R/'src':
  assert {str(p.relative_to(source)):sha(p) for p in source.rglob('*.mojo')}=={str(p.relative_to(dest)):sha(p) for p in dest.rglob('*.mojo')}, 'Frozen source differs; use --out for a new cohort'
(B/'modular').mkdir(exist_ok=True)
(B/'modular/modular.cfg').write_text((H/'modular/modular.cfg').read_text().replace(str(H/'stdlib'),str(B/'stdlib')))
env=os.environ.copy();env['MODULAR_HOME']=str(B/'modular')
cmd=[str(R/'.pixi/envs/default/bin/mojo'),'build','-O3','-g','-D','ASSERT=none','-I',str(B/'source/src'),'-I',str(B/'codec/src'),'-I',str(B/'numojo'),str(R/'tests/large_files/load.mojo'),'-o',str(B/'load')]
with (B/'build.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
identity=dict(effective_snappy_revision='ad02f439892d7b7813677d94f8e0951be63d0041',effective_numojo_revision='515fb2856f0ecf3d2740a34d958fe168183e1129',source=git(R,'rev-parse','HEAD'),source_status=git(R,'status','--short'),snappy=git(R.parent/'mojo-snappy','rev-parse','HEAD'),numojo=git(R.parent/'NuMojo','rev-parse','HEAD'),compiler=subprocess.check_output([cmd[0],'--version'],text=True),cmd=cmd,env={'MODULAR_HOME':env['MODULAR_HOME']},returncode=p.returncode,sha256={str(x.relative_to(R)):sha(x) for root in [B/'source',B/'codec',B/'numojo',B/'stdlib'] for x in root.rglob('*') if x.is_file()})
identity['sha256'].update({str(x.relative_to(R)):sha(x) for x in [R/'pixi.lock',Path(cmd[0]),R/'.pixi/envs/default/lib/libKGENCompilerRTShared.so',R/'tests/large_files/load.mojo',B/'modular/modular.cfg']})
if p.returncode==0:identity['binary_sha256']=sha(B/'load')
(B/'identity.json').write_text(json.dumps(identity,indent=2))
print('build',p.returncode)
if p.returncode:print((B/'build.log').read_text());raise SystemExit(p.returncode)
