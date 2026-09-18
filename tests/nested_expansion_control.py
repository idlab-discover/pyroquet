"""Compact legal billion-element LIST: reject small budget before expansion.

No oracle attempts to materialize this deliberately enormous logical output.
Actual bounded RLE runs and V2 header are inspected without expanding them.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

from fastparquet.cencoding import NumpyIO, ThriftObject
from check_pages import thrift_bytes, T
from nested_controls import OUT, group, leaf, varint, write


def runs(data):
    result, pos = [], 0
    while pos < len(data):
        header = shift = 0
        while True:
            assert pos < len(data) and shift <= 28
            byte = data[pos]
            pos += 1
            header |= (byte & 127) << shift
            if byte < 128:
                break
            shift += 7
        assert header and not header & 1 and pos < len(data)
        result.append(dict(count=header >> 1, value=data[pos]))
        pos += 1
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True, help='tests/nested_load.mojo executable (FILE BUDGET)')
    args = parser.parse_args()
    count = 1_000_000_000
    repetition = varint(2) + b'\x00' + varint(2 * (count - 1)) + b'\x01'
    definition = varint(2 * count) + b'\x02'
    body = repetition + definition
    detail = [(1,T.I32,count),(2,T.I32,count),(3,T.I32,1),(4,T.I32,0),
              (5,T.I32,len(definition)),(6,T.I32,len(repetition)),(7,T.BOOL,False)]
    header = [(1,T.I32,3),(2,T.I32,len(body)),(3,T.I32,len(body)),(8,T.STRUCT,detail)]
    path = OUT / 'oversized-single-list.parquet'
    OUT.mkdir(parents=True, exist_ok=True)
    write(path, [group('schema',1),group('items',1,1,3),group('list',1,2),leaf('element',1)],
          [(['items','list','element'],[thrift_bytes(header) + body],count)], 1)
    raw = path.read_bytes()
    stream = NumpyIO(raw[4:])
    decoded = ThriftObject.from_buffer(stream,'PageHeader')
    start = 4 + stream.tell()
    inspected_body = raw[start:start + decoded.compressed_page_size]
    d = decoded.data_page_header_v2
    r = d.repetition_levels_byte_length
    assert d.num_rows == 1 and d.num_values == d.num_nulls == count
    assert runs(inspected_body[:r]) == [dict(count=1,value=0),dict(count=count-1,value=1)]
    assert runs(inspected_body[r:]) == [dict(count=count,value=2)]
    begin = time.monotonic()
    result = subprocess.run([str(args.binary.resolve()), str(path), '1024'], capture_output=True, text=True, timeout=10)
    elapsed = time.monotonic() - begin
    error = result.stderr + result.stdout
    assert result.returncode != 0 and 'Nested child allocation exceeds budget' in error, result
    report = dict(path=str(path),sha256=hashlib.sha256(raw).hexdigest(),file_bytes=len(raw),
        binary=str(args.binary),binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        format_valid=True,expected_native='reject_budget',parent_rows=1,child_elements=count,
        null_elements=count,page_version=2,value_encoding=0,codec=0,compressed_bytes=len(body),decoded_bytes=len(body),
        repetition_runs=runs(inspected_body[:r]),definition_runs=runs(inspected_body[r:]),
        max_output_bytes=1024,returncode=result.returncode,error=error,elapsed_seconds=elapsed,
        authority=['../parquet-format/README.md Nested Encoding and Nulls','../parquet-format/Encodings.md RLE/Bit-Packing Hybrid', '../parquet-format/src/main/thrift/parquet.thrift DataPageHeaderV2'],
        oracle_status='not attempted: budget rejection control avoids materializing billion-element output; no parity claim')
    (OUT / 'expansion-budget.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Legal billion-element LIST rejected at 1024-byte output budget')


if __name__ == '__main__':
    main()
