"""Reproducible numeric dictionaries: wire fixtures, producers, and three readers.

Run with build/oracle-uv/bin/python. Bulk files and bit-exact semantic manifests
are generated in build/numeric-dictionary-checks. No random seed is needed.
"""
from pathlib import Path
import hashlib
import json
import math
import struct
import subprocess

import duckdb
import fastparquet
from fastparquet import core, converted_types, encoding
from fastparquet.cencoding import ThriftObject
import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

from check_metadata import fields, parts, put, encode
from check_pages import thrift_bytes, T, oracle
from check_numeric import TYPES, ROOT
from check_numeric_write import arrow_values, DUCK_TYPES

OUT = ROOT / 'build/numeric-dictionary-checks'
RESULTS = []
BINARY = OUT / 'read-numeric-dictionary'


def probe(path, dtype):
    return subprocess.run([str(BINARY), dtype, str(path), 'value'], capture_output=True, text=True)


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def packed(ids, width):
    padded = ids + [0] * (-len(ids) % 8)
    word = sum(v << (i * width) for i, v in enumerate(padded))
    return varint((len(padded) // 8) * 2 + 1) + word.to_bytes(len(padded) * width // 8, 'little')


def rle(value, count, width):
    return varint(count * 2) + value.to_bytes((width + 7) // 8, 'little')


def plain(values, dtype):
    width = max(4, getattr(pa, dtype)().bit_width // 8)
    return b''.join((v % (1 << (width * 8))).to_bytes(width, 'little') for v in values)


def page(kind, body, specific, codec=0, level_bytes=0):
    encoded = body
    if codec:
        encoded = body[:level_bytes] + pa.compress(body[level_bytes:], codec='snappy').to_pybytes()
    header = [(1,T.I32,kind),(2,T.I32,len(body)),(3,T.I32,len(encoded)),
              (5 if kind == 0 else 7 if kind == 2 else 8,T.STRUCT,specific)]
    header = thrift_bytes(header)
    return header + encoded, len(header) + len(body)


def dictionary(values, dtype, codec=0, count=None, encoding_id=0, body=None):
    return page(2, plain(values, dtype) if body is None else body,
                [(1,T.I32,len(values) if count is None else count),(2,T.I32,encoding_id)], codec)


def data(ids, width, version=1, codec=0, nullable=False, stream=None, encoding_id=8,
         dtype='int32'):
    present = [v for v in ids if v is not None]
    levels = b''.join(rle(int(v is not None), 1, 1) for v in ids) if nullable else b''
    if encoding_id == 0:
        payload = plain(present, dtype)
    else:
        payload = (bytes([width]) + packed(present, width) if present else bytes([width])) if stream is None else stream
    if version == 1:
        body = (len(levels).to_bytes(4,'little') + levels if nullable else b'') + payload
        return page(0,body,[(1,T.I32,len(ids)),(2,T.I32,encoding_id),(3,T.I32,3),(4,T.I32,3)],codec)
    return page(3,levels + payload,[(1,T.I32,len(ids)),(2,T.I32,ids.count(None)),
                (3,T.I32,len(ids)),(4,T.I32,encoding_id),(5,T.I32,len(levels)),
                (6,T.I32,0),(7,T.BOOL,bool(codec))],codec,len(levels))


def fixture(dtype, groups, nullable=False, codec=0):
    """groups are (pages, logical rows); all offsets/totals derive from bytes."""
    f=fields(); schema,_,_,_=parts(f)
    width=getattr(pa,dtype)().bit_width
    physical=(4 if width==32 else 5) if dtype.startswith('float') else (2 if width==64 else 1)
    schema[1][:]=[(1,T.I32,physical),(3,T.I32,int(nullable)),(4,T.STRING,b'value')]
    if not dtype.startswith('float'):
        schema[1].append((6,T.I32,(15 if dtype.startswith('int') else 11)+[8,16,32,64].index(width)))
    payload=b''; row_groups=[]; total_rows=0
    for pages, rows in groups:
        _,g,_,m=parts(fields()); start=4+len(payload)
        body=b''.join(p[0] for p in pages); uncompressed=sum(p[1] for p in pages)
        headers=[ThriftObject.from_buffer(encoding.NumpyIO(p[0]),'PageHeader') for p in pages]
        offsets=[]; cursor=start
        for p in pages:
            offsets.append(cursor); cursor+=len(p[0])
        data_offset=next((o for o,h in zip(offsets,headers) if h.type in (0,3)),start)
        for field in [(1,T.I32,physical),(2,T.LIST,(T.I32,[0,2,3,8])),
                      (3,T.LIST,(T.STRING,[b'value'])),(4,T.I32,codec),(5,T.I64,rows),
                      (6,T.I64,uncompressed),(7,T.I64,len(body)),(9,T.I64,data_offset)]:put(m,field)
        if any(h.type==2 for h in headers):put(m,(11,T.I64,start))
        put(g,(2,T.I64,uncompressed));put(g,(3,T.I64,rows));row_groups.append(g)
        payload+=body; total_rows+=rows
    put(f,(3,T.I64,total_rows));put(f,(4,T.LIST,(T.STRUCT,row_groups)))
    return encode(f,payload)


def fast_values(path,dtype):
    pf=fastparquet.ParquetFile(path); se=pf.schema.schema_element(['value'])
    assert str(pf.dtypes['value']).lower()==dtype
    raw=path.read_bytes(); result=[]
    for group in pf.row_groups:
        md=group.columns[0].meta_data
        stream=encoding.NumpyIO(raw);stream.seek(md.dictionary_page_offset if md.dictionary_page_offset is not None else md.data_page_offset)
        end=stream.tell()+md.total_compressed_size; dic=None
        while stream.tell()<end:
            h=ThriftObject.from_buffer(stream,'PageHeader')
            if h.type==2:
                body=raw[stream.tell():stream.tell()+h.compressed_page_size]
                stream.seek(stream.tell()+len(body))
                dic=core.read_dictionary_page(encoding.NumpyIO(body),pf.schema,h,md);continue
            dh=h.data_page_header if h.type==0 else h.data_page_header_v2
            if h.type==0:
                defs,_,vals=core.read_data_page(stream,pf.schema,h,md)
                valid=[True]*dh.num_values if defs is None else (defs==1).tolist()
                if dh.encoding in (2,8):vals=dic[vals]
            else:
                body=raw[stream.tell():stream.tell()+h.compressed_page_size];stream.seek(stream.tell()+len(body))
                levels=dh.definition_levels_byte_length
                valid=[True]*dh.num_values
                if se.repetition_type==1:
                    defs=np.zeros(dh.num_values,dtype='uint8')
                    core.encoding.read_rle_bit_packed_hybrid(encoding.NumpyIO(body[:levels]),1,levels,encoding.NumpyIO(defs),itemsize=1)
                    valid=(defs==1).tolist()
                assign=(np.zeros(dh.num_values,dtype=dtype) if dtype.startswith('float') else
                        pd.array(np.zeros(dh.num_values,dtype=dtype),dtype=dtype.replace('int','Int').replace('uInt','UInt')))
                core.read_data_page_v2(encoding.NumpyIO(body),pf.schema,se,dh,md,dic,assign,0,False,0,h)
                vals=(assign._data if hasattr(assign,'_mask') else assign)[np.array(valid,dtype=bool)]
            vals=converted_types.convert(vals,se)
            numbers=iter(vals.view('uint'+str(getattr(pa,dtype)().bit_width)).tolist() if dtype.startswith('float') else vals.tolist())
            result.extend(next(numbers) if v else None for v in valid)
        assert stream.tell()==end
    return result


def check(path,dtype,expected,producer='synthetic',dictionary_required=True):
    entry={'file':path.name,'producer':producer,'dtype':dtype,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
           'expected_bits_or_integers':expected,'oracles':{}}
    RESULTS.append(entry)
    headers=[h for gi in range(len(fastparquet.ParquetFile(path).row_groups)) for h in oracle(path,gi,0)]
    if dictionary_required:
        assert any(h[3]==2 for h in headers),path
        assert any(h[3] in (0,3) and h[10] in (2,8) for h in headers),path
    entry['page_types_encodings']=[[h[3],h[10]] for h in headers]
    pf=fastparquet.ParquetFile(path); am=pq.ParquetFile(path).metadata
    assert pf.count()==am.num_rows==len(expected)
    for gi,group in enumerate(pf.row_groups):
        column=group.columns[0].meta_data; other=am.row_group(gi).column(0)
        for attr in ('num_values','data_page_offset','dictionary_page_offset','total_compressed_size','total_uncompressed_size'):
            assert getattr(column,attr)==getattr(other,attr),(path,attr)
        assert sum(h[9] for h in oracle(path,gi,0) if h[3] in (0,3))==group.num_rows
    result=probe(path,dtype)
    assert result.returncode==0,(path,result.stdout,result.stderr)
    assert result.stdout.splitlines()[0]==f'{len(expected)} {expected.count(None)}'
    actual=[None if x=='null' else int(x) for x in result.stdout.splitlines()[1:]]
    assert actual==expected,(path,actual,expected)
    arrow=pq.read_table(path)['value'];assert arrow.type==getattr(pa,dtype)()
    assert arrow_values(arrow,dtype)==expected,path
    entry['oracles']['PyArrow']='pass: complete values, nulls, types, float bits'
    con=duckdb.connect()
    assert con.execute('DESCRIBE SELECT value FROM read_parquet(?)',[str(path)]).fetchone()[1]==DUCK_TYPES[dtype]
    rows=con.execute('SELECT value, value IS NULL FROM read_parquet(?)',[str(path)]).fetchall();con.close()
    assert len(rows)==len(expected)
    for (actual,null),wanted in zip(rows,expected):
        assert null==(wanted is None)
        if wanted is None:continue
        if dtype.startswith('float'):
            width=getattr(pa,dtype)().bit_width//8; fmt='<f' if width==4 else '<d'
            value=struct.unpack(fmt,wanted.to_bytes(width,'little'))[0]
            assert math.isnan(actual) if math.isnan(value) else struct.pack(fmt,actual)==wanted.to_bytes(width,'little')
        else:assert actual==wanted
    entry['oracles']['DuckDB']='pass: complete values, nulls, types; NaN payload unsupported'
    try:
        assert fast_values(path,dtype)==expected,path
        entry['oracles']['Fastparquet pages']='pass: complete values, nulls, types, float bits'
    except Exception as error:
        assert known_fastparquet_defect(path,error,public=False), (path,error)
        entry['oracles']['Fastparquet pages']='defect: '+type(error).__name__+': '+str(error)
    try:
        public=fastparquet.ParquetFile(path).to_pandas()['value']
        assert len(public)==len(expected)
        assert str(public.dtype).lower()==dtype
        for actual,wanted in zip(public,expected):
            if wanted is None:assert pd.isna(actual)
            elif not dtype.startswith('float'):assert actual==wanted
            else:
                width=getattr(pa,dtype)().bit_width//8;fmt='<f' if width==4 else '<d'
                value=struct.unpack(fmt,wanted.to_bytes(width,'little'))[0]
                assert math.isnan(actual) if math.isnan(value) else struct.pack(fmt,actual)==wanted.to_bytes(width,'little')
        entry['oracles']['Fastparquet public']='pass values/types; float NaN/null distinction unsupported (page reader checked separately)'
    except Exception as error:
        assert known_fastparquet_defect(path,error,public=True), (path,error)
        entry['oracles']['Fastparquet public']='defect: '+type(error).__name__+': '+str(error)


def known_fastparquet_defect(path,error,public):
    """Only reproduced, feature-specific limitations may bypass an assertion."""
    name=path.name
    if name.startswith('cardinality-') and name.endswith('-width32.parquet'):
        return isinstance(error,AssertionError)
    if 'v2' in name and isinstance(error,ValueError):
        return 'NumPy boolean array indexing assignment cannot assign' in str(error)
    if public and 'v2' in name and isinstance(error,IndexError):
        return 'boolean index did not match indexed array' in str(error)
    if public and name.startswith('empty-dictionary-') and '-c0.' in name:
        return isinstance(error,TypeError) and str(error)=='an integer is required'
    return False


def specials(dtype):
    bits=getattr(pa,dtype)().bit_width
    if dtype.startswith('float'):
        return ([0,0x80000000,0x7f800000,0xff800000,0x7fc00001,0xffc12345,0x7f800001,1] if bits==32 else
                [0,0x8000000000000000,0x7ff0000000000000,0xfff0000000000000,0x7ff8000000000001,0xfff8123456789abc,0x7ff0000000000001,1])
    signed=dtype.startswith('int')
    return [0,1,-1 if signed else 2,(1<<(bits-int(signed)))-1,-(1<<(bits-1)) if signed else 1<<(bits-1)]


def arrow_array(values,dtype):
    width=getattr(pa,dtype)().bit_width//8
    validity=sum((v is not None)<<i for i,v in enumerate(values)).to_bytes((len(values)+7)//8,'little')
    raw=b''.join(((v or 0)%(1<<(8*width))).to_bytes(width,'little') for v in values)
    return pa.Array.from_buffers(getattr(pa,dtype)(),len(values),[pa.py_buffer(validity),pa.py_buffer(raw)])


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    subprocess.run(['pixi','run','mojo','build','-O3','-I','src','-I','../NuMojo','tests/read_numeric.mojo','-o',str(BINARY)],cwd=ROOT,check=True)
    for dtype in TYPES:
        values=specials(dtype)
        for version in (1,2):
            for codec in (0,1):
                for nullable in (False,True):
                    expected=[None if nullable and i%7==0 else values[i%len(values)] for i in range(131)]
                    table=pa.Table.from_arrays([arrow_array(expected,dtype)],schema=pa.schema([pa.field('value',getattr(pa,dtype)(),nullable=nullable)]))
                    for use_dict in (True,False):
                        path=OUT/f'arrow-{dtype}-v{version}-c{codec}-n{int(nullable)}-d{int(use_dict)}.parquet'
                        pq.write_table(table,path,use_dictionary=use_dict,compression='snappy' if codec else 'NONE',data_page_version=f'{version}.0',row_group_size=67,data_page_size=128,write_batch_size=17)
                        check(path,dtype,expected,'PyArrow',use_dict)
                    # A synthetic dictionary preserves distinct signed-zero and NaN entries explicitly.
                    ids=list(range(len(values))) + ([None,0,None,1] if nullable else [0,1])
                    path=OUT/f'wire-{dtype}-v{version}-c{codec}-n{int(nullable)}.parquet'
                    pages=[dictionary(values,dtype,codec),data(ids,3,version,codec,nullable,dtype=dtype)]
                    path.write_bytes(fixture(dtype,[(pages,len(ids))],nullable,codec))
                    check(path,dtype,[None if i is None else values[i] for i in ids])
    synthetic_cases()
    truncated_snappy()
    producer_cases()
    roundtrips()
    summary={'versions':{'PyArrow':pa.__version__,'Fastparquet':fastparquet.__version__,'DuckDB':duckdb.__version__},'fixtures':RESULTS}
    (OUT/'results.json').write_text(json.dumps(summary,indent=2))
    defects=[(r['file'],k,v) for r in RESULTS for k,v in r['oracles'].items() if v.startswith('defect')]
    print(json.dumps({'files':len(RESULTS),'oracle_defects':len(defects),'report':str(OUT/'results.json')},indent=2))


def synthetic_cases():
    for cardinality in (1,2,3,7,8,9,15,16,17,255,256,257):
        values=list(range(cardinality));width=(cardinality-1).bit_length();ids=[0,cardinality-1,1%cardinality]*5
        streams={'packed':bytes([width])+packed(ids,width),'rle':bytes([width])+rle(cardinality-1,15,width),
                 'width32':bytes([32])+packed(ids,32)}
        for name,stream in streams.items():
            path=OUT/f'cardinality-{cardinality}-{name}.parquet'
            path.write_bytes(fixture('int32',[([dictionary(values,'int32'),data(ids,width,stream=stream)],len(ids))]))
            check(path,'int32',[cardinality-1]*15 if name=='rle' else ids)
    for version in (1,2):
        for codec in (0,1):
            # Exercise entry materialization beyond small List allocations and
            # ID batches; every entry is observed in deliberately reversed order.
            values=list(range(4097));ids=list(reversed(values))
            path=OUT/f'large-dictionary-v{version}-c{codec}.parquet'
            pages=[dictionary(values,'int32',codec),data(ids,13,version,codec)]
            path.write_bytes(fixture('int32',[(pages,len(ids))],codec=codec))
            check(path,'int32',ids)
            groups=[];expected=[]
            for values in ([11,22,33],[33,11,22]):
                ids=[0,None,1,2,None];nulls=[None]*9
                pages=[dictionary(values,'int32',codec),data(ids,2,version,codec,True),
                       data(nulls,2,version,codec,True),data([2,1,0],2,version,codec,True,encoding_id=2),
                       data([51,None,-17],0,version,codec,True,encoding_id=0)]
                groups.append((pages,20));expected.extend([None if i is None else values[i] for i in ids]+nulls+[values[2],values[1],values[0],51,None,-17])
            path=OUT/f'mixed-v{version}-c{codec}.parquet';path.write_bytes(fixture('int32',groups,True,codec));check(path,'int32',expected)
            # Zero entries and zero IDs obey the same one-byte-width grammar.
            path=OUT/f'empty-dictionary-v{version}-c{codec}.parquet'
            path.write_bytes(fixture('int32',[([dictionary([],'int32',codec),data([None]*3,0,version,codec,True)],3)],True,codec))
            check(path,'int32',[None]*3)
    malformed={
        'id-out-of-bounds':([dictionary([1,2],'int32'),data([0,2,0],2)],3),
        'width33':([dictionary([1],'int32'),data([0]*3,0,stream=b'\x21\x06\0\0\0\0\0')],3),
        'missing-width':([dictionary([1],'int32'),data([0]*3,0,stream=b'')],3),
        'truncated-packed':([dictionary([1,2],'int32'),data([0]*3,1,stream=b'\x01\x03')],3),
        'truncated-varint':([dictionary([1],'int32'),data([0]*3,0,stream=b'\0\x80')],3),
        'overflow-run':([dictionary([1],'int32'),data([0]*3,0,stream=b'\0'+varint(1<<33))],3),
        'overshoot-rle':([dictionary([1],'int32'),data([0]*3,0,stream=b'\0'+rle(0,4,0))],3),
        'dictionary-length':([dictionary([1],'int32',count=2),data([0]*3,0)],3),
        'dictionary-oversized':([dictionary([1],'int32',count=2147483647),data([0]*3,0)],3),
        'dictionary-encoding':([dictionary([1],'int32',encoding_id=8),data([0]*3,0)],3),
        'dictionary-missing':([data([0]*3,0)],3),
        'dictionary-duplicate':([dictionary([1],'int32'),dictionary([2],'int32'),data([0]*3,0)],3),
        'dictionary-late':([data([1]*3,0,encoding_id=0),dictionary([1],'int32')],3),
    }
    for dtype in ('int8','uint8','int16','uint16'):
        bits=getattr(pa,dtype)().bit_width
        malformed['narrow-'+dtype]=([dictionary([1<<(bits-int(dtype.startswith('int')))],dtype),data([0]*3,0)],3,dtype)
        signed=dtype.startswith('int')
        for label,invalid in [('high',1<<(bits-int(signed))),
                              ('low',-(1<<(bits-1))-1 if signed else -1)]:
            # No ID references the invalid entry. The entire dictionary must
            # satisfy the logical type before publication, including unused data.
            for codec in (0,1):
                for version in (1,2):
                    name=f'unreferenced-narrow-{dtype}-{label}-v{version}-c{codec}'
                    pages=[dictionary([1,invalid],dtype,codec),
                           data([0]*3,1,version,codec,dtype=dtype)]
                    malformed[name]=(pages,3,dtype,codec)
    for codec in (0,1):
        for length in (3,5):
            # Both truncated and trailing entry bytes have self-consistent
            # page/footer framing; cardinality still requires exactly four.
            pages=[dictionary([1],'int32',codec,body=b'\0'*length),
                   data([0]*3,0,codec=codec)]
            malformed[f'dictionary-bytes-{length}-c{codec}']=(pages,3,'int32',codec)
    for name,case in malformed.items():
        pages,rows=case[:2];dtype=case[2] if len(case)>2 else 'int32'
        codec=case[3] if len(case)>3 else 0
        path=OUT/f'bad-{name}.parquet';path.write_bytes(fixture(dtype,[(pages,rows)],codec=codec))
        result=probe(path,dtype);assert result.returncode!=0,(name,result.stdout,result.stderr)
        if name.startswith('unreferenced-narrow-'):
            assert 'outside declared narrow range' in result.stdout+result.stderr,(name,result.stdout,result.stderr)
        if name.startswith('dictionary-bytes-'):
            assert 'Dictionary byte length disagrees' in result.stdout+result.stderr,(name,result.stdout,result.stderr)
        assert not result.stdout.splitlines() or result.stdout.splitlines()[0]!='3 0',(name,'partial results')
        RESULTS.append({'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'rejected':True,'oracles':{}})
    for version in (1,2):
        for codec in (0,1):
            # A successful first group must not publish its dictionary into the
            # next group, even when all IDs would fit the previous dictionary.
            groups=[([dictionary([42],'int32',codec),data([0]*3,0,version,codec)],3),
                    ([data([0]*3,0,version,codec)],3)]
            path=OUT/f'bad-dictionary-second-group-v{version}-c{codec}.parquet'
            path.write_bytes(fixture('int32',groups,codec=codec))
            result=probe(path,'int32')
            assert result.returncode!=0 and 'has no dictionary' in result.stdout+result.stderr,(path,result.stdout,result.stderr)
            RESULTS.append({'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'rejected':True,'oracles':{}})


def truncated_snappy():
    for target in ('dictionary','data'):
        d=dictionary([42],'int32',1); p=data([0]*3,0,codec=1)
        original=d if target=='dictionary' else p
        stream=encoding.NumpyIO(original[0]);h=ThriftObject.from_buffer(stream,'PageHeader')
        body=original[0][stream.tell():-1]
        specific=[(1,T.I32,1),(2,T.I32,0)] if target=='dictionary' else [(1,T.I32,3),(2,T.I32,8),(3,T.I32,3),(4,T.I32,3)]
        header=thrift_bytes([(1,T.I32,2 if target=='dictionary' else 0),(2,T.I32,h.uncompressed_page_size),(3,T.I32,len(body)),(7 if target=='dictionary' else 5,T.STRUCT,specific)])
        bad=(header+body,len(header)+h.uncompressed_page_size)
        path=OUT/f'bad-snappy-{target}.parquet'
        path.write_bytes(fixture('int32',[([bad,p] if target=='dictionary' else [d,bad],3)],codec=1))
        result=probe(path,'int32');assert result.returncode!=0,(path,result.stdout,result.stderr)
        RESULTS.append({'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'rejected':True,'oracles':{}})


def roundtrips():
    binary=OUT/'roundtrip'
    subprocess.run(['pixi','run','mojo','build','-O3','-I','src','-I','../NuMojo','tests/roundtrip_numeric.mojo','-o',str(binary)],cwd=ROOT,check=True)
    for dtype in TYPES:
        source=OUT/f'wire-{dtype}-v2-c1-n1.parquet'
        expected=next(r['expected_bits_or_integers'] for r in RESULTS if r['file']==source.name)
        for version in (1,2):
            for codec in (0,1):
                target=OUT/f'roundtrip-{dtype}-v{version}-c{codec}.parquet';target.unlink(missing_ok=True)
                result=subprocess.run([str(binary),dtype,str(source),str(target),'value','1','17','61','1048576','67108864','100000',str(version),str(codec)],capture_output=True,text=True)
                assert result.returncode==0,(source,result.stdout,result.stderr)
                check(target,dtype,expected,'Pyroquet',dictionary_required=False)
                assert all(h[3]!=2 and h[10]==0 for gi in range(len(fastparquet.ParquetFile(target).row_groups)) for h in oracle(target,gi,0))


def hybrid_runs(body,width):
    """Independent wire evidence for the producer's out-of-range padding."""
    offset=0;counts=[]
    while offset<len(body):
        header=shift=0
        while True:
            value=body[offset];offset+=1;header|=(value&127)<<shift;shift+=7
            if value<128:break
        count=(header>>1)*(8 if header&1 else 1);counts.append(count)
        offset+=(count*width//8 if header&1 else (width+7)//8)
    assert offset==len(body)
    return counts


def producer_cases():
    # Fastparquet emits numeric dictionaries for categoricals; DuckDB selects
    # dictionaries itself. Verify page headers rather than trusting options.
    values=[i%13 for i in range(5120)]
    for codec in (None,'SNAPPY'):
        path=OUT/f'fastparquet-{codec}.parquet'
        fastparquet.write(path,pd.DataFrame({'value':pd.Categorical(np.array(values,dtype='int32'))}),compression=codec,has_nulls=False)
        # Fastparquet 2026.5.0 appends eight bytes beyond its packed run.
        # This violates the page ID stream length; preserve rejection evidence.
        result=probe(path,'int32')
        assert result.returncode and 'hybrid stream has trailing data' in result.stdout+result.stderr
        headers=oracle(path,0,0)
        assert [h[3] for h in headers]==[2,0] and headers[1][10]==8
        RESULTS.append({'file':path.name,'producer':'Fastparquet','sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                        'expected_bits_or_integers':values,'rejected':True,
                        'oracles':{'Fastparquet producer':'invalid fixture: eight trailing bytes beyond packed ID run'}})
        path=OUT/f'duckdb-{codec}.parquet';path.unlink(missing_ok=True)
        con=duckdb.connect();con.execute("COPY (SELECT (i % 13)::INTEGER AS value FROM range(5120) t(i)) TO ? (FORMAT PARQUET, COMPRESSION "+('SNAPPY' if codec else 'UNCOMPRESSED')+")",[str(path)]);con.close()
        check(path,'int32',values,'DuckDB')
        path=OUT/f'duckdb-{codec}-excess-padding.parquet';path.unlink(missing_ok=True)
        con=duckdb.connect();con.execute("COPY (SELECT (i % 13)::INTEGER AS value FROM range(5000) t(i)) TO ? (FORMAT PARQUET, COMPRESSION "+('SNAPPY' if codec else 'UNCOMPRESSED')+")",[str(path)]);con.close()
        result=probe(path,'int32');assert result.returncode and 'hybrid packed run exceeds value count' in result.stdout+result.stderr
        wire=oracle(path,0,0);h=next(h for h in wire if h[3]==0)
        body=path.read_bytes()[h[1]:h[2]]
        if codec:body=pa.decompress(body,h[4],codec='snappy').to_pybytes()
        level_length=int.from_bytes(body[:4],'little'); ids=body[4+level_length:]
        runs=hybrid_runs(ids[1:],ids[0]);assert sum(runs)-5000>7
        RESULTS.append({'file':path.name,'producer':'DuckDB','sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                        'expected_bits_or_integers':[i%13 for i in range(5000)],'packed_run_counts':runs,'rejected':True,
                        'oracles':{'DuckDB producer':'invalid fixture: final packed run pads beyond one eight-value group'}})
    for dtype in TYPES:
        for version in (1,2):
            for label,values in [('empty',[]),('all-null',[None]*37)]:
                path=OUT/f'arrow-{dtype}-v{version}-{label}.parquet'
                pq.write_table(pa.table({'value':pa.array(values,type=getattr(pa,dtype)())}),path,use_dictionary=True,data_page_version=f'{version}.0',compression='snappy')
                check(path,dtype,values,'PyArrow',dictionary_required=bool(values))


if __name__=='__main__':
    try:main()
    finally:
        if OUT.exists():(OUT/'partial-results.json').write_text(json.dumps(RESULTS,indent=2))
