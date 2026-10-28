"""Independent metadata oracle, real-writer fixtures, and adversarial Thrift cases.

Run with build/oracle-uv/bin/python tests/check_metadata.py.
Dependencies: fastparquet, pyarrow, thrift; native Mojo comes from Pixi.
Artifacts stay under ignored build/metadata-checks.
"""
from pathlib import Path
import struct
import subprocess

import fastparquet
import pyarrow as pa
import pyarrow.parquet as pq
from thrift.Thrift import TType as T
from thrift.protocol.TCompactProtocol import TCompactProtocol
from thrift.transport.TTransport import TMemoryBuffer
from check_compact_interop import write_struct

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/metadata-checks'
BINARY = OUT / 'inspect'


def encode(fields, payload=b'\0' * 32):
    buffer = TMemoryBuffer()
    write_struct(TCompactProtocol(buffer), fields)
    footer = buffer.getvalue()
    return b'PAR1' + payload + footer + struct.pack('<I', len(footer)) + b'PAR1'


def fields():
    schema = [
        [(4,T.STRING,b'schema'),(5,T.I32,1)],
        [(1,T.I32,1),(3,T.I32,1),(4,T.STRING,b'x'),(6,T.I32,13)],
    ]
    col = [(1,T.I32,1),(2,T.LIST,(T.I32,[0,3])),(3,T.LIST,(T.STRING,[b'x'])),
           (4,T.I32,0),(5,T.I64,3),(6,T.I64,32),(7,T.I64,32),(9,T.I64,4)]
    group = [(1,T.LIST,(T.STRUCT,[[(2,T.I64,0),(3,T.STRUCT,col)]])),
             (2,T.I64,32),(3,T.I64,3)]
    return [(1,T.I32,1),(2,T.LIST,(T.STRUCT,schema)),(3,T.I64,3),(4,T.LIST,(T.STRUCT,[group]))]


def parts(f):
    schema = f[1][2][1]
    group = f[3][2][1][0]
    chunk = group[0][2][1][0]
    col = chunk[1][2]
    return schema, group, chunk, col


def put(target, field):
    target[:] = [f for f in target if f[0] != field[0]] + [field]


def probe(path):
    return subprocess.run([str(BINARY),str(path)], capture_output=True, text=True)


def text(s):
    return s.decode() if isinstance(s,bytes) else s


def compare(path):
    result = probe(path)
    if result.returncode:
        raise AssertionError(f'{path}: {result.stdout}{result.stderr}')
    lines = iter(result.stdout.splitlines())
    f = fastparquet.ParquetFile(path).fmd
    assert next(lines) == f'{f.version} {f.num_rows} {len(f.schema)} {len(f.row_groups)}'
    stack = []
    for i,s in enumerate(f.schema):
        while stack and stack[-1][1] == 0:
            stack.pop()
        parent, definition, repetition = -1,0,0
        if i:
            parent = stack[-1][0]
            stack[-1][1] -= 1
            definition = stack[-1][2] + int(s.repetition_type in (1,2))
            repetition = stack[-1][3] + int(s.repetition_type == 2)
        if s.type is None:
            stack.append([i,s.num_children,definition,repetition])
        row = next(lines).split(' ',11)
        raw = [parent, s.type, s.repetition_type, s.num_children, s.converted_type]
        assert list(map(int,row[1:6])) == [-1 if x is None else x for x in raw], (path,row,s)
        assert list(map(int,row[9:11])) == [definition,repetition]
        assert row[11] == text(s.name)
        assert next(lines) == f'L {-1 if s.type_length is None else s.type_length}'
        integer = s.logicalType.INTEGER if s.logicalType else None
        if integer:
            assert list(map(int,row[6:10])) == [10,integer.bitWidth,int(integer.isSigned),definition]
        elif s.logicalType is None and s.converted_type == 13:
            assert list(map(int,row[7:9])) == [32,0]
    leaves = [i for i,s in enumerate(f.schema) if s.type is not None]
    for g in f.row_groups:
        total = -1 if g.total_compressed_size is None else g.total_compressed_size
        assert next(lines) == f'R {g.num_rows} {g.total_byte_size} {total} {-1 if g.file_offset is None else g.file_offset}'
        for leaf,c in zip(leaves,g.columns):
            m=c.meta_data
            dictionary = -1 if m.dictionary_page_offset is None else m.dictionary_page_offset
            assert next(lines) == f'C {leaf} {m.type} {m.codec} {m.num_values} {m.data_page_offset} {dictionary} {m.total_compressed_size} {m.total_uncompressed_size}'
            optional = [c.file_offset, m.index_page_offset, c.offset_index_offset,
                        c.offset_index_length, c.column_index_offset, c.column_index_length,
                        m.bloom_filter_offset, getattr(m, 'bloom_filter_length', None)]
            assert next(lines) == 'A ' + ' '.join(str(-1 if x is None else x) for x in optional)
            for p in m.path_in_schema:
                assert next(lines) == f'P {text(p)}'
            for e in m.encodings:
                assert next(lines) == f'E {e}'
    assert list(lines) == []
    # Arrow independently exposes chunk fields even when its schema is normalized.
    arrow=pq.ParquetFile(path).metadata
    assert arrow.num_rows == f.num_rows
    for gi,g in enumerate(f.row_groups):
        for ci,c in enumerate(g.columns):
            a=arrow.row_group(gi).column(ci)
            for n in ('num_values','data_page_offset','dictionary_page_offset','total_compressed_size','total_uncompressed_size'):
                assert getattr(a,n) == getattr(c.meta_data,n), (path,n)


def adversarial():
    cases=[]
    def case(name, change):
        f=fields(); change(f,*parts(f)); cases.append((name,f))
    for field in (1,2,3,4,5,6,7,9):
        case(f'missing_column_{field}',lambda f,s,g,c,m,k=field: m.__setitem__(slice(None),[x for x in m if x[0]!=k]))
    case('duplicate_schema_name',lambda f,s,g,c,m: s[1].append((4,T.STRING,b'x')))
    case('missing_name',lambda f,s,g,c,m: s[1].__setitem__(slice(None),[x for x in s[1] if x[0]!=4]))
    case('missing_repetition',lambda f,s,g,c,m: s[1].__setitem__(slice(None),[x for x in s[1] if x[0]!=3]))
    case('bad_repetition',lambda f,s,g,c,m: put(s[1],(3,T.I32,3)))
    case('extra_schema_node',lambda f,s,g,c,m: put(s[0],(5,T.I32,0)))
    case('missing_schema_node',lambda f,s,g,c,m: put(s[0],(5,T.I32,2)))
    case('primitive_children',lambda f,s,g,c,m: s[1].append((5,T.I32,0)))
    case('fixed_missing_length',lambda f,s,g,c,m: put(s[1],(1,T.I32,7)))
    case('path_mismatch',lambda f,s,g,c,m: put(m,(3,T.LIST,(T.STRING,[b'wrong']))))
    case('physical_mismatch',lambda f,s,g,c,m: put(m,(1,T.I32,2)))
    case('value_count',lambda f,s,g,c,m: put(m,(5,T.I64,4)))
    case('negative_size',lambda f,s,g,c,m: put(m,(7,T.I64,-1)))
    case('huge_size',lambda f,s,g,c,m: put(m,(7,T.I64,2**63-1)))
    case('before_magic',lambda f,s,g,c,m: put(m,(9,T.I64,0)))
    case('into_footer',lambda f,s,g,c,m: put(m,(9,T.I64,5)))
    case('dictionary_after_data',lambda f,s,g,c,m: put(m,(11,T.I64,5)))
    case('index_missing_length',lambda f,s,g,c,m: c.append((4,T.I64,4)))
    case('index_into_footer',lambda f,s,g,c,m: c.extend([(4,T.I64,35),(5,T.I32,2)]))
    case('column_index_into_footer',lambda f,s,g,c,m: c.extend([(6,T.I64,35),(7,T.I32,2)]))
    case('bloom_into_footer',lambda f,s,g,c,m: m.extend([(14,T.I64,35),(15,T.I32,2)]))
    case('bloom_missing_offset',lambda f,s,g,c,m: m.append((15,T.I32,1)))
    case('external',lambda f,s,g,c,m: c.append((1,T.STRING,b'elsewhere.parquet')))
    case('encrypted',lambda f,s,g,c,m: c.append((9,T.STRING,b'ciphertext')))
    case('empty_logical_union',lambda f,s,g,c,m: s[1].append((10,T.STRUCT,[])))
    case('multiple_logical_union',lambda f,s,g,c,m: s[1].append((10,T.STRUCT,[(1,T.STRUCT,[]),(6,T.STRUCT,[])])))
    case('missing_integer_signed',lambda f,s,g,c,m: s[1].append((10,T.STRUCT,[(10,T.STRUCT,[(1,T.BYTE,32)])])))
    case('wrong_integer_boolean',lambda f,s,g,c,m: s[1].append((10,T.STRUCT,[(10,T.STRUCT,[(1,T.BYTE,32),(2,T.I32,0)])])))
    for name,f in cases:
        p=OUT/(name+'.parquet');p.write_bytes(encode(f))
        r=probe(p)
        assert r.returncode and 'Unhandled exception' in r.stdout+r.stderr, (name,r.stdout,r.stderr)
    # Modern signed annotation overrides stale legacy unsigned annotation.
    for name,annotation,expected in [
        ('modern_uint32',[(10,T.STRUCT,[(1,T.BYTE,32),(2,T.BOOL,False)])],(10,32,0)),
        ('modern_precedence',[(10,T.STRUCT,[(1,T.BYTE,32),(2,T.BOOL,True)])],(10,32,1)),
        ('unknown_annotation',[(99,T.STRUCT,[])],(99,0,1)),
        ('incompatible_integer',[(10,T.STRUCT,[(1,T.BYTE,64),(2,T.BOOL,False)])],(10,0,0)),
    ]:
        f=fields();parts(f)[0][1].append((10,T.STRUCT,annotation))
        p=OUT/(name+'.parquet');p.write_bytes(encode(f));r=probe(p)
        assert r.returncode==0,(name,r.stdout,r.stderr)
        assert tuple(map(int,r.stdout.splitlines()[3].split()[6:9]))==expected
    # The deprecated file_offset is not a page address.
    f=fields();put(parts(f)[2],(2,T.I64,2**63-1));p=OUT/'deprecated_offset.parquet';p.write_bytes(encode(f));assert probe(p).returncode==0
    return len(cases)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    subprocess.run(['pixi','run','mojo','build','-O3','-D','ASSERT=all','-I','src','tests/inspect_metadata.mojo','-o',str(BINARY)],cwd=ROOT,check=True)
    paths=list((ROOT/'build/fixtures/uint32').glob('*.parquet'))
    assert len(paths)==9,'Generate UInt32 fixtures first'
    nested=pa.table({
        'a.b':pa.array([1,None,2],pa.uint32()),
        'struct':pa.array([{'x':1},None,{'x':None}],pa.struct([pa.field('x',pa.uint32())])),
        'list':pa.array([[1,None],None,[]],pa.list_(pa.uint32())),
        'fixed':pa.array([b'ab',None,b'cd'],pa.binary(2)),
        'bool':pa.array([True,None,False]),
        'int64':pa.array([1,None,-1],pa.int64()),
        'float':pa.array([1,None,2],pa.float32()),
        'double':pa.array([1,None,2],pa.float64()),
        'string':pa.array(['hello',None,'world']),
    })
    for version in ('1.0','2.0'):
        for codec in ('NONE','snappy','gzip','zstd'):
            p=OUT/f'nested-{version}-{codec}.parquet'
            pq.write_table(nested,p,data_page_version=version,compression=codec,row_group_size=2,write_page_index=True)
            paths.append(p)
    p=OUT/'empty-dictionary.parquet'
    pq.write_table(pa.table({'x':pa.array([],pa.uint32())}),p)
    paths.append(p)
    for p in paths:compare(p)
    rejected=adversarial()
    print(f'Matched {len(paths)} files against fastparquet schema/chunks and PyArrow chunks; rejected {rejected} malformed/unsupported cases; passed 5 annotation/compatibility cases.')

if __name__=='__main__':main()
