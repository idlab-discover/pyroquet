"""Compare native page headers and exact boundaries with fastparquet.

Generate fixtures with PyArrow and the existing UInt32 fixture generator.
Bodies are not decoded by the native implementation.
"""
from pathlib import Path
import subprocess
import zlib
import fastparquet
from fastparquet.cencoding import NumpyIO, ThriftObject
import pyarrow as pa
import pyarrow.parquet as pq
from thrift.Thrift import TType as T
from thrift.protocol.TCompactProtocol import TCompactProtocol
from thrift.transport.TTransport import TMemoryBuffer
from check_compact_interop import write_struct
from check_metadata import fields, parts, put, encode

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/page-checks'
BINARY=OUT/'inspect'


def thrift_bytes(fields):
    b=TMemoryBuffer();write_struct(TCompactProtocol(b),fields);return b.getvalue()


def header_fields(kind=0, size=12):
    specific={
        0:[(1,T.I32,3),(2,T.I32,0),(3,T.I32,3),(4,T.I32,3)],
        1:[],
        2:[(1,T.I32,3),(2,T.I32,0)],
        3:[(1,T.I32,3),(2,T.I32,1),(3,T.I32,3),(4,T.I32,0),(5,T.I32,2),(6,T.I32,0)],
    }[kind]
    return [(1,T.I32,kind),(2,T.I32,size),(3,T.I32,size),(kind+5,T.STRUCT,specific)]


def synthetic(header=None, payload=b'\0'*12, num_values=3, data_offset=4):
    if header is None:header=header_fields()
    data=thrift_bytes(header)+payload
    f=fields();s,g,c,m=parts(f)
    put(m,(6,T.I64,len(data)));put(m,(7,T.I64,len(data)))
    put(m,(5,T.I64,num_values));put(m,(9,T.I64,data_offset))
    put(g,(2,T.I64,len(data)));put(g,(3,T.I64,num_values));put(f,(3,T.I64,num_values))
    return encode(f,payload=data)


def probe(path, rg=0, col=0):
    return subprocess.run([str(BINARY),str(path),str(rg),str(col)],text=True,capture_output=True)


def oracle(path, rg, ci):
    md=fastparquet.ParquetFile(path).row_groups[rg].columns[ci].meta_data
    start=md.dictionary_page_offset if md.dictionary_page_offset is not None else md.data_page_offset
    end=start+md.total_compressed_size
    rows=[]
    with path.open('rb') as f:
        offset=start
        while offset<end:
            f.seek(offset)
            stream=NumpyIO(f.read(min(65536,end-offset)))
            h=ThriftObject.from_buffer(stream,'PageHeader')
            hs=stream.tell();payload=offset+hs;next_offset=payload+h.compressed_page_size
            fields=[offset,payload,next_offset,h.type,h.uncompressed_page_size,h.compressed_page_size,hs,
                    int(h.crc is not None),h.crc or 0]
            defaults=[-1,-1,-1,-1,-1,-1,-1,-1,1,0,0]
            if h.type==0:
                d=h.data_page_header
                defaults[:4]=[d.num_values,d.encoding,d.definition_level_encoding,d.repetition_level_encoding]
            elif h.type==2:
                d=h.dictionary_page_header
                defaults[:2]=[d.num_values,d.encoding]
                defaults[-2:]=[int(d.is_sorted is not None),int(d.is_sorted or False)]
            elif h.type==3:
                d=h.data_page_header_v2
                defaults[:9]=[d.num_values,d.encoding,3,3,d.num_nulls,d.num_rows,
                              d.definition_levels_byte_length,d.repetition_levels_byte_length,
                              int(True if d.is_compressed is None else d.is_compressed)]
            rows.append(fields+defaults)
            assert next_offset<=end
            if h.crc is not None:
                f.seek(payload)
                assert zlib.crc32(f.read(h.compressed_page_size)) == h.crc & 0xffffffff
            offset=next_offset
    return rows


def compare(path):
    f=fastparquet.ParquetFile(path)
    count=0
    for gi,g in enumerate(f.row_groups):
        for ci,c in enumerate(g.columns):
            r=probe(path,gi,ci)
            assert r.returncode==0,(path,gi,ci,r.stdout,r.stderr)
            actual=[list(map(int,line.split())) for line in r.stdout.splitlines()]
            expected=oracle(path,gi,ci)
            assert actual==expected,(path,gi,ci,actual,expected)
            count+=len(actual)
    return count


def malformed():
    cases=[]
    for field in (1,2,3,5):
        cases.append((f'missing_{field}',[f for f in header_fields() if f[0]!=field]))
    cases += [
        ('duplicate',header_fields()+[(1,T.I32,0)]),
        ('wrong_specific',header_fields()[:3]+[(7,T.STRUCT,[(1,T.I32,3),(2,T.I32,0)])]),
        ('multiple_specific',header_fields()+[(6,T.STRUCT,[])]),
        ('unknown_page',[(1,T.I32,99)]+header_fields()[1:]),
        ('negative_size',[(2,T.I32,-1)]+[f for f in header_fields() if f[0]!=2]),
        ('oversized_payload',[(3,T.I32,1000)]+[f for f in header_fields() if f[0]!=3]),
        ('missing_v1_encoding',header_fields()[:3]+[(5,T.STRUCT,[(1,T.I32,3)])]),
        ('v2_levels_outside',header_fields(3)[:3]+[(8,T.STRUCT,[(1,T.I32,3),(2,T.I32,1),(3,T.I32,3),(4,T.I32,0),(5,T.I32,13),(6,T.I32,0)])]),
        ('v2_nulls',header_fields(3)[:3]+[(8,T.STRUCT,[(1,T.I32,3),(2,T.I32,4),(3,T.I32,3),(4,T.I32,0),(5,T.I32,2),(6,T.I32,0)])]),
    ]
    for name,h in cases:
        p=OUT/f'bad-{name}.parquet';p.write_bytes(synthetic(h))
        r=probe(p);assert r.returncode!=0,(name,r.stdout)
    # Length-consistent footer with a short payload must fail at the chunk boundary.
    p=OUT/'bad-truncated-payload.parquet';p.write_bytes(synthetic(payload=b'\0'))
    assert probe(p).returncode!=0
    p=OUT/'valid-synthetic.parquet';p.write_bytes(synthetic());assert probe(p).returncode==0
    for rg,ci in [(-1,0),(1,0),(0,-1),(0,1)]:assert probe(p,rg,ci).returncode!=0
    return len(cases)+1+4


def chunk_cases():
    def page(kind):
        return thrift_bytes(header_fields(kind)) + b'\0'*12
    dictionary=page(2);data=page(0)
    def file_for(body, dictionary_offset=-1, data_offset=4, extra_uncompressed=0):
        f=fields();s,g,c,m=parts(f)
        put(m,(6,T.I64,len(body)+extra_uncompressed));put(m,(7,T.I64,len(body)))
        put(m,(9,T.I64,data_offset));put(g,(2,T.I64,len(body)+extra_uncompressed))
        if dictionary_offset!=-1:put(m,(11,T.I64,dictionary_offset))
        return encode(f,payload=body)
    cases=[
        ('dictionary-first',file_for(dictionary+data,4,4+len(dictionary)),True),
        ('dictionary-second',file_for(data+dictionary,4,5),False),
        ('dictionary-duplicate',file_for(dictionary+dictionary+data,4,4+2*len(dictionary)),False),
        ('wrong-data-offset',file_for(dictionary+data,4,5),False),
        ('wrong-uncompressed-total',file_for(data,extra_uncompressed=1),False),
        ('wrong-value-total',file_for(data+data),False),
    ]
    for name,body,valid in cases:
        p=OUT/(name+'.parquet');p.write_bytes(body);r=probe(p)
        assert (r.returncode==0)==valid,(name,r.stdout,r.stderr)
    p=OUT/'dictionary-first.parquet'
    r=subprocess.run([str(BINARY),str(p),'0','0','1'],capture_output=True,text=True)
    assert r.returncode!=0 and 'Page count exceeds' in r.stdout+r.stderr
    return len(cases)+1


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    subprocess.run(['pixi','run','mojo','build','-O3','-D','ASSERT=all','-I','src','-I','../NuMojo','tests/inspect_pages.mojo','-o',str(BINARY)],cwd=ROOT,check=True)
    paths=list((ROOT/'build/fixtures/uint32').glob('*.parquet'))
    assert len(paths)==9,'Run make_uint32_fixtures.py first'
    for version in ('1.0','2.0'):
        for codec in ('NONE','snappy','gzip','zstd'):
            for dictionary in (False,True):
                p=OUT/f'pages-{version}-{codec}-{dictionary}.parquet'
                data=pa.table({'x':pa.array([None if i%7==0 else i%32 for i in range(4096)],pa.uint32()),
                               'list':pa.array([[1,None,2],None,[],[3]]*1024,pa.list_(pa.uint32()))})
                pq.write_table(data,p,data_page_version=version,compression=codec,use_dictionary=dictionary,
                               data_page_size=128,write_batch_size=64,row_group_size=2048,
                               write_page_checksum=True,write_page_index=True)
                paths.append(p)
    p=OUT/'empty-dictionary.parquet';pq.write_table(pa.table({'x':pa.array([],pa.uint32())}),p);paths.append(p)
    count=sum(compare(p) for p in paths)
    bad=malformed()
    chunks=chunk_cases()
    print(f'Matched {count} page headers/boundaries in {len(paths)} files against fastparquet; rejected {bad} malformed/range/index cases; passed {chunks} chunk sequence/limit cases.')

if __name__=='__main__':main()
