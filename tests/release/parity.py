"""Complete, chunk-bounded qualification comparisons; limitations are nonpasses."""
from __future__ import annotations
import argparse
import hashlib
import re
import json
import os
import time
import subprocess
from pathlib import Path
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

CHUNK = 65536
RECORD = np.dtype([('valid', 'u1'), ('bits', '<u8')])
KINDS = {1:'uint32',2:'int8',3:'uint8',4:'int16',5:'uint16',6:'int32',7:'int64',8:'uint64',9:'float32',10:'float64',11:'bool',12:'binary',13:'fixed_binary',15:'string',16:'enum',17:'float16'}


def export_native(path, binary, out, budget):
    out = Path(out); out.mkdir(parents=True, exist_ok=False)
    command = [str(binary), str(path), str(out), str(budget)]
    started = time.monotonic()
    with (out/'stdout.txt').open('w') as stdout, (out/'stderr.txt').open('w') as stderr:
        run = subprocess.Popen(command, stdout=stdout, stderr=stderr)
        _, status, usage = os.wait4(run.pid, 0)
        run.returncode = os.waitstatus_to_exitcode(status)
    (out/'resource.json').write_text(json.dumps(dict(max_rss_kib=usage.ru_maxrss, elapsed_seconds=time.monotonic()-started)))
    if run.returncode:
        raise RuntimeError(f'native export failed ({run.returncode}): {(out/"stderr.txt").read_text()[-3000:]}')
    result = dict(nodes=[], timings=[], command=command, budget=budget)
    for line in (out/'stdout.txt').read_text().splitlines():
        fields = line.split()
        if fields[0] in ('WARMUP','TIME'):
            result['timings'].append(fields)
        elif fields[0] == 'TABLE':
            result.update(rows=int(fields[1]), node_count=int(fields[2]))
        elif fields[0] == 'NODE':
            node = dict(zip(('id','kind','parent','nullable','width','count','bytes'), map(int, fields[1:8])))
            node['name'] = bytes.fromhex(fields[8]).decode('utf8') if len(fields)>8 else ''
            result['nodes'].append(node)
    if len(result['nodes']) != result['node_count']:
        raise ValueError('incomplete native schema')
    result['resources'] = json.loads((out/'resource.json').read_text())
    widths={1:4,2:1,3:1,4:2,5:2,6:4,7:8,8:8,9:4,10:8,17:2}
    estimate=0
    for node in result['nodes']:
        count=node['count'];kind=node['kind']
        estimate+=(count+7)//8 if node['nullable'] else 0
        if kind in widths: estimate+=count*widths[kind]
        elif kind==11: estimate+=(count+7)//8
        elif kind==14: estimate+=(count+1)*8
        elif kind in (12,15): estimate+=node['bytes']+(count+1)*8
        elif kind==13: estimate+=count*node['width']
        elif kind==16: estimate+=count*4+node['bytes']+(count+1)*8
    result['storage_estimate_bytes']=estimate
    result['storage_estimate_scope']='Schema-derived payload/offset/nullable-mask estimate; ENUM assumes unshared labels. Excludes allocator capacity, schema, codec scratch and object overhead; not measured RSS.'
    result['export_bytes']=sum(n['count']*9+n['bytes'] for n in result['nodes'])
    (out/'descriptor.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


class Export:
    def __init__(self, directory):
        self.directory=Path(directory)
        self.description=json.loads((self.directory/'descriptor.json').read_text())
        self.nodes=self.description['nodes']
        self.records={}
        self.payloads={}
        for n in self.nodes:
            p=self.directory/f'{n["id"]}.bin'
            if p.stat().st_size != n['count']*9: raise ValueError(f'bad record extent: {p}')
            self.records[n['id']]=np.memmap(p,dtype=RECORD,mode='r') if n['count'] else np.empty(0,dtype=RECORD)
            if n['kind'] in (12,13,15,16):
                p=self.directory/f'{n["id"]}.data'
                if p.stat().st_size != n['bytes']: raise ValueError('bad byte extent')
                self.payloads[n['id']]=np.memmap(p,dtype='u1',mode='r') if n['bytes'] else np.empty(0,dtype='u1')
    def children(self, parent): return [n for n in self.nodes if n['parent']==parent]
    def compare(self, node, array, offsets, engine, limitations, ancestors=None):
        idx=node['id']; start=offsets.get(idx,0); stop=start+len(array)
        actual=self.records[idx][start:stop]
        if len(actual)!=len(array): raise ValueError(f'{node["name"]}: row extent at {start}')
        valid=np.asarray(array.is_valid())
        if ancestors is not None: valid=valid & ancestors
        if not np.array_equal(actual['valid'].astype(bool),valid): raise ValueError(f'{node["name"]}: null mask at {start}')
        kind=node['kind']
        if kind==0:
            if not pa.types.is_struct(array.type): raise ValueError('STRUCT representation mismatch')
            for child in self.children(idx): self.compare(child,array.field(child['name']),offsets,engine,limitations,valid)
        elif kind==14:
            if not pa.types.is_list(array.type): raise ValueError('LIST representation mismatch')
            off=np.asarray(array.offsets); lengths=np.diff(off).copy(); lengths[~valid]=0
            prior=int(self.records[idx][start-1]['bits']) if start else 0
            ends=np.cumsum(lengths,dtype=np.uint64)+prior
            if not np.array_equal(actual['bits'],ends): raise ValueError(f'{node["name"]}: LIST offsets at {start}')
            if np.all(valid | (np.diff(off)==0)):
                child_array=array.values.slice(int(off[0]),int(off[-1]-off[0]))
            else:
                pieces=[array.values.slice(int(off[i]),int(off[i+1]-off[i])) for i in range(len(array)) if valid[i]]
                child_array=pa.concat_arrays(pieces) if pieces else pa.array([],type=array.type.value_type)
            self.compare(self.children(idx)[0],child_array,offsets,engine,limitations)
        elif kind in (12,13,15,16):
            payload=self.payloads[idx]
            prior=int(self.records[idx][start-1]['bits']) if start else 0
            for i, scalar in enumerate(array):
                end=int(actual[i]['bits']); value=scalar.as_py() if valid[i] else None
                expected=b'' if value is None else value.encode('utf8') if isinstance(value,str) else bytes(value)
                if bytes(payload[prior:end])!=expected: raise ValueError(f'{node["name"]}: bytes at {start+i}')
                prior=end
        else:
            if kind in (9,10,17):
                width={9:32,10:64,17:16}[kind]
                if engine=='duckdb' and kind==17 and pa.types.is_float32(array.type):
                    limitations.append('DuckDB FLOAT16 widened to FLOAT32; original NaN payload bits unavailable')
                    array=array.cast(pa.float16())
                if not pa.types.is_floating(array.type) or array.type.bit_width!=width:
                    raise ValueError(f'{node["name"]}: floating width mismatch {array.type}')
                bits=array.fill_null(0).to_numpy(zero_copy_only=False).view(f'uint{width}').astype('uint64')
            else:
                bits=array.fill_null(False if kind==11 else 0).to_numpy(zero_copy_only=False).astype('uint64')
            bits[~valid]=0
            if engine=='duckdb' and kind in (9,10,17):
                dtype=f'uint{width}'
                expected_nan=np.isnan(actual['bits'].astype(dtype).view(f'float{width}')) & valid
                oracle_nan=np.isnan(bits.astype(dtype).view(f'float{width}')) & valid
                if np.any(expected_nan) and np.array_equal(expected_nan,oracle_nan):
                    if not np.array_equal(actual['bits'][expected_nan],bits[expected_nan]):
                        limitations.append('DuckDB NaN payload bits changed; NaN locations and other floating bits compared')
                    bits[expected_nan]=actual['bits'][expected_nan]
            if not np.array_equal(actual['bits'],bits): raise ValueError(f'{node["name"]}: payload bits at {start}')
        offsets[idx]=stop


def arrow_kind(dtype):
    if pa.types.is_struct(dtype): return 0,0
    if pa.types.is_list(dtype): return 14,0
    if pa.types.is_fixed_size_binary(dtype): return 13,dtype.byte_width
    if pa.types.is_binary(dtype): return 12,0
    if pa.types.is_string(dtype): return 15,0
    aliases={'halffloat':'float16','float':'float32','double':'float64'}
    name=aliases.get(str(dtype),str(dtype))
    return next((k for k,v in KINDS.items() if v==name),-1),0


def schema_compare(export, schema, engine):
    limitations=[]
    def walk(parent, fields):
        nodes=export.children(parent)
        if len(nodes)!=len(fields): raise ValueError('schema field count')
        for n,f in zip(nodes,fields):
            if n['name']!=f.name and not (parent and export.nodes[parent-1]['kind']==14): raise ValueError('schema name/order')
            kind,width=arrow_kind(f.type)
            if engine=='duckdb' and n['kind']==17 and kind==9: limitations.append('DuckDB FLOAT16 logical type widened to FLOAT32')
            elif n['kind']==16 and kind in (12,15): limitations.append('ENUM logical identity unavailable in result type')
            elif engine=='duckdb' and n['kind']==13 and kind==12: limitations.append('FIXED_BINARY width unavailable in DuckDB BLOB')
            elif (kind,width)!=(n['kind'],n['width']): raise ValueError(f'schema type: {n["name"]} native {n["kind"]} oracle {f.type}')
            if engine=='pyarrow' and bool(n['nullable'])!=f.nullable: raise ValueError('schema nullability')
            if kind==0: walk(n['id'],list(f.type))
            elif kind==14: walk(n['id'],[f.type.value_field])
    walk(0,list(schema))
    if engine=='duckdb': limitations.append('SQL result nullability unavailable')
    return limitations


def catalog_review(path,column,group_index,error,result):
    import fastparquet
    if fastparquet.__version__!='2026.5.0':return None
    if result['engines'].get('pyarrow',{}).get('dimensions',{}).get('values')!='pass':return None
    if result['engines'].get('duckdb',{}).get('status') not in ('pass','with_limitations'):return None
    path=Path(path)
    def sha(p):
        with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
    catalog=json.loads(Path(__file__).with_name('oracle_limitations.json').read_text())
    record=next((r for r in catalog['fixtures'] if r['path']==path.name),None)
    if record is None or record['sha256']!=sha(path):return None
    issue=next((i for i in record['issues'] if i['column']==column and i['row_group']==group_index),None)
    if issue is None:return None
    controls=[]
    for item in record['controls']:
        control=path.parent/item['path']
        if not control.exists() or sha(control)!=item['sha256']:return None
        controls.append(control)
    if issue['error']=='an integer is required':
        if str(error)!=issue['error']:return None
        values=fastparquet.ParquetFile(controls[0])[group_index].to_pandas(columns=[column])[column]
        if not values.isna().all():return None
        # Full Arrow equality independently checks the compression-only control.
        if not pq.read_table(path).equals(pq.read_table(controls[0])):return None
    else:
        if not re.fullmatch(re.escape(column)+r': null mask at \d+',str(error)):return None
        source=fastparquet.ParquetFile(path)[group_index].to_pandas(columns=[column])[column].tolist()
        wrong=fastparquet.ParquetFile(controls[0])[group_index].to_pandas(columns=[column])[column].tolist()
        correct=fastparquet.ParquetFile(controls[1])[group_index].to_pandas(columns=[column])[column].tolist()
        expected=pq.ParquetFile(path).read_row_group(group_index,columns=[column]).column(0).to_pylist()
        bad=[i for i,(a,b) in enumerate(zip(source,expected)) if (a is None)!=(b is None)]
        if bad!=issue['local_rows'] or source!=wrong or correct!=expected:return None
    return dict(status='reviewed_disagreement_not_pass',column=column,row_group=group_index,error=str(error),fixture_sha256=record['sha256'],controls=record['controls'],issue=issue)


def review_fastparquet_error(path,column,group_index,error,result,out=None):
    """Only generated, hash-pinned V2 cases with independently reproduced errors."""
    import fastparquet
    known=catalog_review(path,column,group_index,error,result)
    if known is not None:return known
    if (out is not None
            and result['engines'].get('pyarrow',{}).get('dimensions',{}).get('values')=='pass'
            and result['engines'].get('duckdb',{}).get('dimensions',{}).get('values')=='pass'):
        from list_controls import review_large_list
        reviewed=review_large_list(path,column,group_index,error,out)
        if reviewed is not None:return reviewed
    message=str(error)
    patterns=(r'NumPy boolean array indexing assignment cannot assign \d+ input values to the \d+ output values where the mask is true',
              r'boolean index did not match indexed array along axis 0; size of axis is \d+ but size of corresponding boolean axis is \d+',
              r"cannot access local variable 'defi' where it is not associated with a value")
    if fastparquet.__version__!='2026.5.0' or not any(re.fullmatch(p,message) for p in patterns): return None
    if result['engines'].get('pyarrow',{}).get('dimensions',{}).get('values')!='pass': return None
    path=Path(path); manifest=path.parent/'manifest.json'
    if not manifest.exists(): return None
    entries=json.loads(manifest.read_text())['files']
    case=next((f for f in entries if f['path']==path.name),None)
    if not case or case['category']!='small' or case['options']['page_version']!=2: return None
    def sha(p):
        with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
    if sha(path)!=case['sha256']: return None
    control_name=re.sub(r'-c[0-9]+-', '-c0-', path.name)
    control_case=next((f for f in entries if f['path']==control_name),None)
    if not control_case: return None
    control=path.parent/control_name
    if sha(control)!=control_case['sha256'] or control_case['options']['codec']!=0: return None
    if not all(e['page_version']==2 for e in case['pages']['encodings'] if e['page_type'] in (0,3)): return None
    # Matching uncompressed control must independently decode identically in Arrow.
    if not pq.read_table(path,columns=[column]).equals(pq.read_table(control,columns=[column])): return None
    try: fastparquet.ParquetFile(control)[group_index].to_pandas(columns=[column])
    except Exception as control_error:
        if type(control_error) is not type(error) or str(control_error)!=message:return None
    else:return None
    return dict(status='reviewed_reader_error_not_pass',oracle='fastparquet',version=fastparquet.__version__,column=column,row_group=group_index,error=message,fixture_sha256=case['sha256'],control=str(control),control_sha256=control_case['sha256'])


def compare_export(path, export_dir):
    import duckdb, fastparquet
    export=Export(export_dir); result=dict(status='pass',engines={},unexpected=[])
    pf=pq.ParquetFile(path)
    if pf.metadata.num_rows!=export.description['rows']:
        result['unexpected'].append(dict(engine='native_metadata',error='exported row count differs from Parquet footer'))
    for engine in ('pyarrow','duckdb','fastparquet'):
        entry=dict(dimensions={},limitations=[]); result['engines'][engine]=entry
        offsets={}; connection=None
        try:
            if engine=='pyarrow':
                entry['limitations']+=schema_compare(export,pf.schema_arrow,engine)
                batches=pf.iter_batches(batch_size=CHUNK,use_threads=False)
            elif engine=='duckdb':
                connection=duckdb.connect(); connection.execute('SET threads=1'); connection.execute('SET preserve_insertion_order=true')
                batches=connection.execute('SELECT * FROM read_parquet(?, hive_partitioning=false)',[str(path)]).fetch_record_batch(CHUNK)
                entry['limitations']+=schema_compare(export,batches.schema,engine)
            else:
                fp=fastparquet.ParquetFile(path)
                if fp.count()!=export.description['rows']: raise ValueError('footer row count')
                if len(fp.row_groups)!=pf.metadata.num_row_groups: raise ValueError('footer row groups')
                for gi,g in enumerate(fp.row_groups):
                    if g.num_rows!=pf.metadata.row_group(gi).num_rows: raise ValueError('row group rows')
                    for ci,c in enumerate(g.columns):
                        for key in ('num_values','total_compressed_size','total_uncompressed_size','data_page_offset','dictionary_page_offset'):
                            if getattr(c.meta_data,key)!=getattr(pf.metadata.row_group(gi).column(ci),key): raise ValueError('footer '+key)
                entry['dimensions']['metadata']='pass rows, groups, column sizes and offsets'
                skipped=set()
                entry['reviewed_reader_errors']=[]
                for group_index in range(len(fp.row_groups)):
                    class Frame:
                        def __contains__(self,name): return name in fp.columns
                        def __getitem__(self,name): return fp[group_index].to_pandas(columns=[name])[name]
                    frame=Frame()
                    def field_walk(parent,fields,prefix=()):
                        for node,field in zip(export.children(parent),fields):
                            names=prefix+(field.name,)
                            if node['kind']==0:
                                entry['limitations'].append('Fastparquet STRUCT parent validity unavailable')
                                field_walk(node['id'],list(field.type),names)
                            else:
                                name='.'.join(names)
                                if name not in frame: raise ValueError(f'Fastparquet missing field {name}')
                                try:
                                    series=frame[name]
                                except Exception as error:
                                    review=review_fastparquet_error(path,name,group_index,error,result,export.directory)
                                    if review is None: raise
                                    entry['reviewed_reader_errors'].append(review)
                                    entry['limitations'].append(f'Fastparquet {name}: reviewed reader error; values/nulls/order unavailable for row group {group_index}')
                                    skipped.add(node['id'])
                                    offsets[node['id']]=offsets.get(node['id'],0)+fp.row_groups[group_index].num_rows
                                    if node['kind']==14:
                                        child=export.children(node['id'])[0]
                                        end=offsets[node['id']]
                                        offsets[child['id']]=int(export.records[node['id']][end-1]['bits']) if end else 0
                                        skipped.add(child['id'])
                                    continue
                                if node['kind'] in (1,2,3,4,5,6,7,8,9,10,11):
                                    expected=KINDS[node['kind']]
                                    if str(series.dtype).lower().replace('boolean','bool')!=expected:
                                        raise ValueError(f'{name}: pandas dtype {series.dtype} differs from {expected}')
                                elif node['kind'] in (14,15,16,17,12,13):
                                    entry['limitations'].append(f'Fastparquet {name}: pandas object representation does not preserve logical type')
                                # Nullable floats lose NaN/null distinction; retain a nonpass.
                                if node['kind'] != 17 and pa.types.is_floating(field.type) and series.isna().any():
                                    entry['limitations'].append(f'Fastparquet {name}: NaN/null ambiguity')
                                    start=offsets.get(node['id'],0)
                                    native=export.records[node['id']][start:start+len(series)]
                                    values=series.to_numpy(); nan=np.isnan(values)
                                    valid=native['valid'].astype(bool)
                                    wanted=native['bits'].astype(f'uint{field.type.bit_width}').view(f'float{field.type.bit_width}')
                                    if not np.array_equal(nan,np.isnan(wanted)|~valid): raise ValueError(f'{name}: NaN/null union mismatch')
                                    if not np.array_equal(values[valid].view(f'uint{field.type.bit_width}'),wanted[valid].view(f'uint{field.type.bit_width}')): raise ValueError(f'{name}: floating payload mismatch')
                                    offsets[node['id']]=start+len(series)
                                else:
                                    if node['kind']==17 and any(isinstance(x,bytes) for x in series):
                                        entry['limitations'].append('Fastparquet FLOAT16 returned raw fixed bytes; logical type unavailable, trailing NUL bytes erased')
                                        values=[None if x is None else np.frombuffer(bytes(x).ljust(2,b'\0'),dtype='<f2')[0] for x in series]
                                        arr=pa.array(values,type=pa.float16(),from_pandas=False)
                                    elif node['kind']==13 and any(isinstance(x,bytes) and len(x)!=node['width'] for x in series):
                                        entry['limitations'].append('Fastparquet FIXED_BINARY trailing NUL bytes erased; reconstructed width is not byte-preservation evidence')
                                        arr=pa.array([None if x is None else bytes(x).ljust(node['width'],b'\0') for x in series],type=field.type)
                                    else:
                                        arr=pa.array(series,type=field.type,from_pandas=True)
                                    try:
                                        export.compare(node,arr,offsets,engine,entry['limitations'])
                                    except ValueError as error:
                                        review=catalog_review(path,name,group_index,error,result)
                                        if review is None:raise
                                        entry['reviewed_reader_errors'].append(review)
                                        entry['limitations'].append(f'Fastparquet {name}: reviewed reader error/value mismatch; values/nulls/order unavailable for row group {group_index}')
                                        offsets[node['id']]=offsets.get(node['id'],0)+len(series)
                                        if node['kind']==14:
                                            child=export.children(node['id'])[0]
                                            end=offsets[node['id']]
                                            offsets[child['id']]=int(export.records[node['id']][end-1]['bits']) if end else 0
                    field_walk(0,list(pf.schema_arrow))
                batches=[]
            observed_rows=0
            for batch in batches:
                observed_rows+=batch.num_rows
                for node,array in zip(export.children(0),batch.columns): export.compare(node,array,offsets,engine,entry['limitations'])
            if engine!='fastparquet' and observed_rows!=export.description['rows']:
                raise ValueError('oracle batch row count differs from exported row count')
            for node in export.nodes:
                if engine=='fastparquet' and node['kind']==0: continue
                if offsets.get(node['id'],0)!=node['count']: raise ValueError(f'incomplete node {node["name"]}')
            limited_values=any(any(term in x for term in ('payload bits','trailing NUL','reader error')) for x in entry['limitations'])
            limited_nulls=any(any(term in x for term in ('NaN/null','parent validity','reader error')) for x in entry['limitations'])
            entry['dimensions'].update(values='see limitations' if limited_values else 'pass',nulls='see limitations' if limited_nulls else 'pass',order='see limitations' if entry.get('reviewed_reader_errors') else 'pass',schema='pass' if not entry['limitations'] else 'see limitations')
            entry['limitations']=sorted(set(entry['limitations']))
            entry['status']='with_limitations' if entry['limitations'] else 'pass'
        except Exception as error:
            entry.update(status='failed',error=str(error))
            result['unexpected'].append(dict(engine=engine,error=str(error)))
        finally:
            if connection is not None: connection.close()
    result['limitations']=[dict(engine=engine,reason=reason) for engine,e in result['engines'].items() for reason in e['limitations']]
    result['status']='failed' if result['unexpected'] else 'with_limitations' if any(e['limitations'] for e in result['engines'].values()) else 'pass'
    return result


def main():
    p=argparse.ArgumentParser(); p.add_argument('--file',required=True); p.add_argument('--binary',required=True); p.add_argument('--out',required=True); p.add_argument('--budget',type=int,required=True); a=p.parse_args()
    export_native(a.file,a.binary,a.out,a.budget)
    result=compare_export(a.file,a.out)
    (Path(a.out)/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result)); return bool(result['unexpected'])

if __name__=='__main__': raise SystemExit(main())
