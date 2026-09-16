"""Independent uncommon/malformed Boolean and binary wire corpus."""
import hashlib
import json
import struct
import subprocess
import pyarrow as pa
from fastparquet.cencoding import ThriftObject, NumpyIO
from check_metadata import fields, parts, put, encode
from check_pages import T
from check_numeric_dictionary import page, packed, rle
from check_binary import OUT, BINARY, native, readers, RESULTS


def fixture(name, physical, pages, rows, codec, width=0):
    f = fields()
    schema, group, _, md = parts(f)
    schema[1][:] = [(1,T.I32,physical),(3,T.I32,1),(4,T.STRING,name.encode())]
    if width:
        schema[1].append((2,T.I32,width))
    body = b''.join(p[0] for p in pages)
    raw_size = sum(p[1] for p in pages)
    headers = [ThriftObject.from_buffer(NumpyIO(p[0]), 'PageHeader') for p in pages]
    offset = 4
    data_offset = None
    for p, h in zip(pages, headers):
        if h.type in (0,3) and data_offset is None:
            data_offset = offset
        offset += len(p[0])
    for field in [(1,T.I32,physical),(2,T.LIST,(T.I32,[0,3,8])),(3,T.LIST,(T.STRING,[name.encode()])),(4,T.I32,codec),(5,T.I64,rows),(6,T.I64,raw_size),(7,T.I64,len(body)),(9,T.I64,data_offset)]:
        put(md,field)
    if headers[0].type == 2:
        put(md,(11,T.I64,4))
    put(group,(2,T.I64,raw_size));put(group,(3,T.I64,rows));put(f,(3,T.I64,rows))
    def ordered(fs):
        for _, typ, val in fs:
            if typ == T.STRUCT:
                ordered(val)
            elif typ == T.LIST and val[0] == T.STRUCT:
                for child in val[1]:
                    ordered(child)
        fs.sort(key=lambda field: field[0])
    ordered(f)
    return encode(f, body)


def data(values, payload, version, codec, encoding):
    levels = packed([int(v is not None) for v in values], 1)
    if version == 1:
        return page(0, struct.pack('<I',len(levels)) + levels + payload, [(1,T.I32,len(values)),(2,T.I32,encoding),(3,T.I32,3),(4,T.I32,3)], codec)
    return page(3, levels + payload, [(1,T.I32,len(values)),(2,T.I32,values.count(None)),(3,T.I32,len(values)),(4,T.I32,encoding),(5,T.I32,len(levels)),(6,T.I32,0),(7,T.BOOL,bool(codec))], codec, len(levels))


def plain(values, fixed=False):
    return b''.join((b'' if fixed else struct.pack('<I',len(v))) + v for v in values if v is not None)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    records = []
    for version in (1,2):
        for codec in (0,1):
            vals = [True, None, False, True, None, True, False, True, True]
            present = [int(v) for v in vals if v is not None]
            stream = packed(present, 1)
            prefix = struct.pack('<I',len(stream))
            first = data(vals, prefix + stream, version, codec, 3)
            tail = [False, True, None]
            second = data(tail, b'\x02', version, codec, 0)
            p = OUT / f'wire-bool-rle-v{version}-c{codec}.parquet'
            p.write_bytes(fixture('flag',0,[first,second],len(vals)+len(tail),codec))
            native(p, {'flag': vals + tail})
            readers(p, {'flag': vals + tail})
            records.append({'file':p.name,'values':vals+tail})
            for fixed in (False,True):
                entries = [b'\0\xff\0',b'\x80\0\xff'] if fixed else [b'',b'\0\xff',b'\x80']
                ids = [0,None,1,0,1,None,0]
                expected = [None if v is None else entries[v] for v in ids]
                dictionary = page(2,plain(entries,fixed),[(1,T.I32,len(entries)),(2,T.I32,0)],codec)
                indexed = data(ids,b'\x01'+packed([v for v in ids if v is not None],1),version,codec,8)
                tail = [entries[1],None,entries[0]]
                direct = data(tail,plain(tail,fixed),version,codec,0)
                name = 'fixed' if fixed else 'raw'
                p=OUT/f'wire-{name}-mixed-v{version}-c{codec}.parquet'
                p.write_bytes(fixture(name,7 if fixed else 6,[dictionary,indexed,direct],len(ids)+len(tail),codec,width=3 if fixed else 0))
                native(p,{name:expected+tail})
                readers(p,{name:expected+tail})
                records.append({'file':p.name,'values':[None if v is None else v.hex() for v in expected+tail]})
            malformed = {
                'bool-prefix': ('flag',0,[data(vals,b'\x00\0\0\0'+stream,version,codec,3)],len(vals)),
                'bool-truncated': ('flag',0,[data(vals,b'',version,codec,0)],len(vals)),
                'binary-overrun': ('raw',6,[data([b'x'],b'\x02\0\0\0x',version,codec,0)],1),
                'binary-negative': ('raw',6,[data([b'x'],b'\xff'*4,version,codec,0)],1),
                'dictionary-truncated': ('raw',6,[page(2,b'\x02\0\0\0x',[(1,T.I32,1),(2,T.I32,0)],codec),data([0],b'\0'+rle(0,1,0),version,codec,8)],1),
            }
            for label,(name,physical,pages,rows) in malformed.items():
                p=OUT/f'invalid-{label}-v{version}-c{codec}.parquet'
                p.write_bytes(fixture(name,physical,pages,rows,codec))
                result=subprocess.run([str(BINARY),str(p)],capture_output=True,text=True)
                assert result.returncode != 0 and 'Unhandled exception' in result.stdout+result.stderr, (p,result)
                records.append({'file':p.name,'expected':'reject','error':(result.stdout+result.stderr).strip()})
    (OUT/'wire-results.json').write_text(json.dumps({'cases':records,'oracles':RESULTS,'hashes':{r['file']:hashlib.sha256((OUT/r['file']).read_bytes()).hexdigest() for r in records}},indent=2))
    print(len(records),'wire cases validated')
    for r in RESULTS:
        if r[2]!='pass': print(*r)


if __name__=='__main__':main()
