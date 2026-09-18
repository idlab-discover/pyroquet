"""Complete-value oracle checks outside timing for synthetic encoding cohorts.

Run with build/oracle-uv/bin/python. Native binaries must be rebuilt from current
source: tests/read_nested.mojo and tests/read_numeric.mojo (read-numeric-delta).
Fastparquet runs isolated; crashes/errors/mismatches are retained, never passes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

import duckdb
import numpy as np
import pyarrow.parquet as pq
from nested_fixture_oracle import ROOT, compare

PERF=ROOT/'build/nested-performance'


def flat_fastparquet(entry):
    path=Path(entry['path'])
    arrow=pq.ParquetFile(path).read().column('x').combine_chunks()
    values=arrow.fill_null(0).to_numpy().astype('<i8',copy=False)
    mask=arrow.is_null().to_numpy(zero_copy_only=False).astype(np.uint8)
    expected=dict(rows=len(arrow), values_sha256=hashlib.sha256(values.tobytes()).hexdigest(),nulls_sha256=hashlib.sha256(mask.tobytes()).hexdigest())
    script="""import sys,json,hashlib,numpy as np,fastparquet
s=fastparquet.ParquetFile(sys.argv[1]).to_pandas()['x']
v=s.to_numpy(dtype='<i8',na_value=0); m=s.isna().to_numpy(dtype=np.uint8)
print(json.dumps(dict(rows=len(s),values_sha256=hashlib.sha256(v.tobytes()).hexdigest(),nulls_sha256=hashlib.sha256(m.tobytes()).hexdigest())))
"""
    run=subprocess.run([sys.executable,'-c',script,str(path)],capture_output=True,text=True)
    if run.returncode:
        return dict(status='reader_error',returncode=run.returncode,error=run.stderr,expected=expected)
    actual=json.loads(run.stdout)
    return dict(status='pass' if actual==expected else 'value_mismatch',actual=actual,expected=expected)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--fastparquet-only',action='store_true');args=parser.parse_args()
    manifest=json.loads((PERF/'manifest.json').read_text())
    if args.fastparquet_only:
        result=[]
        for entry in manifest['fixtures']:
            if entry['shape']=='flat':
                r=flat_fastparquet(entry);result.append(dict(path=entry['path'],sha256=entry['sha256'],fastparquet=r));print(Path(entry['path']).name,r['status'],flush=True)
        (PERF/'fastparquet-correctness.json').write_text(json.dumps(result,indent=2)+'\n')
        return
    result=[]
    for entry in manifest['fixtures']:
        path=Path(entry['path']);started=time.monotonic();print('Checking',path.name,flush=True)
        if entry['shape']=='nested':
            comparison=compare(path,ROOT/'build/read-nested')
        else:
            proc=subprocess.run([str(ROOT/'build/read-numeric-delta'),'int64',str(path),'x'],text=True,capture_output=True)
            if proc.returncode:raise RuntimeError(proc.stderr)
            lines=proc.stdout.splitlines();actual=[None if v=='null' else int(v) for v in lines[1:]]
            expected=pq.ParquetFile(path).read().column('x').to_pylist()
            assert actual==expected
            duck=[r[0] for r in duckdb.connect().execute('select x from read_parquet(?, hive_partitioning=false)',[str(path)]).fetchall()]
            assert duck==expected
            comparison=dict(native='pass',pyarrow='pass',duckdb='pass',rows=len(expected),fastparquet=flat_fastparquet(entry))
            del actual,expected,duck,lines,proc
        assert comparison['native']=='pass' and comparison['duckdb']=='pass',comparison
        result.append(dict(path=str(path),sha256=entry['sha256'],comparison=comparison,validation_seconds=time.monotonic()-started))
        (PERF/'correctness.json').write_text(json.dumps(result,indent=2)+'\n')
        print('Pass',path.name,round(time.monotonic()-started,1),flush=True)


if __name__=='__main__':
    main()
