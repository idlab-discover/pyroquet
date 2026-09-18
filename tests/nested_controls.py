"""Spec-derived independent nested PLAIN controls; generated files stay in build.

README Nested Encoding/Nulls/Data Pages; LogicalTypes Nested Types and Lists
backward compatibility rules 1 and 5; parquet.thrift DataPageHeaderV2 row rules.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import argparse

from check_pages import thrift_bytes, T
from nested_fixture_oracle import OUT, page_evidence, compare


def varint(n):
    result = bytearray()
    while n >= 128:
        result.append((n & 127) | 128); n >>= 7
    result.append(n)
    return bytes(result)


def levels(values, maximum):
    return b''.join(varint(2) + v.to_bytes((maximum.bit_length() + 7) // 8, 'little') for v in values)


def data_page(reps, defs, vals, maxrep, maxdef, version=1, extra=b''):
    r = levels(reps, maxrep) if maxrep else b''
    d = levels(defs, maxdef) if maxdef else b''
    body = (struct.pack('<I', len(r)) + r if maxrep else b'') + (struct.pack('<I', len(d)) + d if maxdef else b'') if version == 1 else r + d
    body += b''.join(struct.pack('<i', x) for x in vals) + extra
    if version == 1:
        detail = [(1,T.I32,len(defs)),(2,T.I32,0),(3,T.I32,3),(4,T.I32,3)]
    else:
        detail = [(1,T.I32,len(defs)),(2,T.I32,len(defs)-len(vals)),(3,T.I32,reps.count(0)),(4,T.I32,0),(5,T.I32,len(d)),(6,T.I32,len(r)),(7,T.BOOL,False)]
    h = [(1,T.I32,0 if version == 1 else 3),(2,T.I32,len(body)),(3,T.I32,len(body)),(5 if version == 1 else 8,T.STRUCT,detail)]
    return thrift_bytes(h) + body


def write(path, schema, columns, rows):
    body = bytearray(b'PAR1')
    chunks = []
    for names, pages, count in columns:
        offset = len(body)
        payload = b''.join(pages)
        md = [(1,T.I32,1),(2,T.LIST,(T.I32,[0,3])),(3,T.LIST,(T.STRING,[x.encode() for x in names])),(4,T.I32,0),(5,T.I64,count),(6,T.I64,len(payload)),(7,T.I64,len(payload)),(9,T.I64,offset)]
        chunks.append([(2,T.I64,offset),(3,T.STRUCT,md)])
        body.extend(payload)
    rg = [(1,T.LIST,(T.STRUCT,chunks)),(2,T.I64,len(body)-4),(3,T.I64,rows)]
    fmd = [(1,T.I32,1),(2,T.LIST,(T.STRUCT,schema)),(3,T.I64,rows),(4,T.LIST,(T.STRUCT,[rg])),(6,T.STRING,b'pyroquet independent spec control v1')]
    footer = thrift_bytes(fmd)
    path.write_bytes(body + footer + struct.pack('<I', len(footer)) + b'PAR1')


def group(name, children, repetition=0, annotation=None):
    result = [(3,T.I32,repetition),(4,T.STRING,name.encode()),(5,T.I32,children)]
    if annotation is not None:
        result.append((6,T.I32,annotation))
    return result


def leaf(name, repetition=0):
    return [(1,T.I32,1),(3,T.I32,repetition),(4,T.STRING,name.encode())]


def generate():
    OUT.mkdir(parents=True, exist_ok=True)
    report = []
    def record(name, schema, cols, rows, valid=True, reason=''):
        path = OUT / (name+'.parquet')
        write(path,schema,cols,rows)
        entry = dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),valid=valid,format_valid=valid or name == 'unsupported-array-wrapper',expected_native='accept' if valid else 'reject_unsupported' if name == 'unsupported-array-wrapper' else 'reject_malformed',reason=reason,
            authority=['../parquet-format/README.md#nested-encoding','../parquet-format/LogicalTypes.md#backward-compatibility-rules','../parquet-format/src/main/thrift/parquet.thrift:DataPageHeaderV2'])
        try:
            entry['pages'] = page_evidence(path)
        except Exception as error:
            entry['page_probe_error'] = str(error)
        if valid:
            entry['oracles'] = compare(path)
        report.append(entry)
    schema=[group('schema',1),group('items',1,1,3),group('list',1,2),leaf('element',1)]
    # rows: null, [], [null,10,20,30], [40]. Deliberately cut the long row.
    p1=data_page([0,0,0,1],[0,1,2,3],[10],1,3)
    p2=data_page([1,1,0],[3,3,3],[20,30,40],1,3)
    record('v1-continuation',schema,[(['items','list','element'],[p1,p2],7)],4)
    record('v2-illegal-continuation',schema,[(['items','list','element'],[data_page([0,0,0,1],[0,1,2,3],[10],1,3,2),data_page([1,1,0],[3,3,3],[20,30,40],1,3,2)],7)],4,False,'V2 pages must begin at row boundaries')
    record('invalid-first-repetition',schema,[(['items','list','element'],[data_page([1],[3],[9],1,3)],1)],1,False,'First entry cannot continue absent row')
    record('invalid-definition',schema,[(['items','list','element'],[data_page([0],[4],[],1,3)],1)],1,False,'Definition exceeds schema maximum')
    record('missing-physical-value',schema,[(['items','list','element'],[data_page([0],[3],[],1,3)],1)],1,False,'Defined element requires physical value')
    record('extra-physical-payload',schema,[(['items','list','element'],[data_page([0],[3],[9],1,3,extra=b'X')],1)],1,False,'README Data Pages prohibits extra padding')
    # Required legacy primitive LIST with required elements: [], [1,2], [3].
    record('legacy-repeated-primitive',[group('schema',1),leaf('items',2)],[(['items'],[data_page([0,0,1,0],[0,1,1,1],[1,2,3],1,1)],4)],3)
    # Two-level optional LIST: null, [], [1,2], [3].
    record('legacy-two-level',[group('schema',1),group('items',1,1,3),leaf('value',2)],[(['items','value'],[data_page([0,0,0,1,0],[0,1,2,2,2],[1,2,3],1,2)],5)],4)
    # Rule5 permits arbitrary wrapper/element names.
    record('legacy-renamed-wrapper',[group('schema',1),group('items',1,1,3),group('bag',1,2),leaf('v',1)],[(['items','bag','v'],[p1,p2],7)],4)
    # Required STRUCT child null under null optional parent, independent cuts.
    structschema=[group('schema',1),group('s',2,1),leaf('x',0),leaf('y',1)]
    x=[data_page([0,0],[0,1],[11],0,1),data_page([0,0],[1,1],[22,33],0,1)]
    y=[data_page([0],[0],[],0,2),data_page([0,0,0],[1,2,1],[44],0,2)]
    record('struct-independent-pages',structschema,[(['s','x'],x,4),(['s','y'],y,4)],4)
    ybad=[data_page([0],[1],[],0,2),data_page([0,0,0],[1,2,1],[44],0,2)]
    record('struct-inconsistent-parent',structschema,[(['s','x'],x,4),(['s','y'],ybad,4)],4,False,'Sibling leaves disagree on parent definition')
    # Names triggering rule4 denote LIST<STRUCT>, explicitly outside supported scope.
    record('unsupported-array-wrapper',[group('schema',1),group('items',1,1,3),group('array',1,2),leaf('v',1)],[(['items','array','v'],[p1,p2],7)],4,False,'LogicalTypes LIST backward rule4 is LIST<STRUCT>, not primitive LIST')
    (OUT/'controls.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',type=Path)
    args=parser.parse_args()
    report=generate()
    if args.binary:
        for entry in report:
            if entry['valid']:
                try:
                    entry['parity']=compare(Path(entry['path']),args.binary)
                    entry['native']=entry['parity']['native']
                except Exception as error:
                    entry['native']=dict(status='error',error=str(error))
            else:
                p=subprocess.run([str(args.binary),entry['path']],capture_output=True,text=True)
                entry['native']='rejected' if p.returncode else 'incorrectly accepted'
                entry['error']=p.stderr
            print(Path(entry['path']).name,entry.get('native'))
        (OUT/'control-parity.json').write_text(json.dumps(report,indent=2)+'\n')
        assert all(e['native'] == ('pass' if e['valid'] else 'rejected') for e in report), 'Unexpected native control outcome'


if __name__=='__main__':
    main()
