"""Current-source original projections and explicit component-path controls.

Uses complete canonical comparisons from nested_fixture_oracle; does not count
Fastparquet STRUCT flattening as a parity pass. Reports stay in ignored build/.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import struct

import fastparquet
from fastparquet.cencoding import NumpyIO, ThriftObject

from nested_fixture_oracle import ROOT, OUT, compare, page_evidence


def repaired_offsets(source):
    """Change only footer offsets in a labeled derivative; preserve source bytes."""
    raw = source.read_bytes()
    pf = fastparquet.ParquetFile(source)
    records = []
    for gi, group in enumerate(pf.row_groups):
        for col in group.columns:
            md = col.meta_data
            start = min(v for v in (md.dictionary_page_offset, md.data_page_offset) if v is not None)
            end = start + md.total_compressed_size
            actual_dictionary = actual_data = None
            headers = []
            while start < end:
                stream = NumpyIO(raw[start:end])
                h = ThriftObject.from_buffer(stream, 'PageHeader')
                detail = h.dictionary_page_header if h.type == 2 else h.data_page_header if h.type == 0 else h.data_page_header_v2
                headers.append(dict(offset=start, page_type=h.type, value_encoding=detail.encoding,
                    codec=md.codec, compressed_bytes=h.compressed_page_size, decoded_bytes=h.uncompressed_page_size))
                if h.type == 2:
                    assert actual_dictionary is None
                    actual_dictionary = start
                elif h.type in (0, 3) and actual_data is None:
                    actual_data = start
                start += stream.tell() + h.compressed_page_size
            assert start == end
            if md.dictionary_page_offset != actual_dictionary or md.data_page_offset != actual_data:
                records.append(dict(row_group=gi, path=md.path_in_schema,
                    declared_data_page_offset=md.data_page_offset,
                    declared_dictionary_page_offset=md.dictionary_page_offset,
                    actual_data_page_offset=actual_data,
                    actual_dictionary_page_offset=actual_dictionary, headers=headers))
                md.dictionary_page_offset = actual_dictionary
                md.data_page_offset = actual_data
    assert records
    footer_start = len(raw) - 8 - struct.unpack_from('<I', raw, len(raw) - 8)[0]
    footer = bytes(pf.fmd.to_bytes())
    target = OUT / 'corrected-offsets' / source.name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(raw[:footer_start] + footer + struct.pack('<I', len(footer)) + b'PAR1')
    assert target.read_bytes()[:footer_start] == raw[:footer_start]
    assert source.read_bytes() == raw
    return target, dict(source=str(source), source_sha256=hashlib.sha256(raw).hexdigest(),
        derivative=str(target), derivative_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
        authority='../parquet-format/src/main/thrift/parquet.thrift ColumnMetaData fields 9 and 11, lines 935-942',
        operation='Footer offsets only; all page bytes unchanged. This is not an original corpus pass.', findings=records)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, action='append', required=True)
    args = parser.parse_args()
    original = ROOT / 'build/coverage-ledger-gzip-standalone/fixtures'
    fixture = OUT / 'nested-2.0-DELTA_BINARY_PACKED.parquet'
    fixed_nested, nested_evidence = repaired_offsets(original / 'nested1.parquet')
    fixed_v2, v2_evidence = repaired_offsets(original / 'datapage_v2.snappy.parquet')
    cases = [
        (original / 'nested1.parquet', [['_adobe_corpnew', 'id']]),
        (original / 'datapage_v2.snappy.parquet', [['b']]),
        (fixed_nested, [['_adobe_corpnew', name] for name in ('id', 'frequency', 'max_len', 'reduced_max_len')]),
        (fixed_v2, [['b'], ['e']]),
        (fixture, [['s', 'x'], ['s', 'inner', 'z'], ['s', 'items']]),
        (fixture, [['literal.dot']]),
    ]
    rejected = [
        (original / 'nested1.parquet', ['_adobe_corpnew', 'frequency'], 'Independent original metadata offset violation'),
        (original / 'datapage_v2.snappy.parquet', ['b', '--', 'e'], 'Independent original metadata offset violation'),
        (original / 'nested1.parquet', [], 'complete table includes unsupported STRING'),
        (original / 'nested1.parquet', ['_adobe_corpnew'], 'whole STRUCT includes unsupported STRING'),
        (original / 'datapage_v2.snappy.parquet', [], 'complete table includes unsupported STRING'),
        (original / 'datapage_v2.snappy.parquet', ['a'], 'annotated STRING is not raw binary'),
        (fixture, ['literal', 'dot'], 'literal dotted name is not a component path'),
        (fixture, ['s', '--', 's', 'x'], 'overlapping paths are rejected'),
        (fixture, ['s', 'items', 'element'], 'LIST element traversal is outside STRUCT-child projection'),
    ]
    report = dict(source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), binaries=[], projections=[], rejections=[], controls=[])
    report['offset_blockers_and_derivatives'] = [nested_evidence, v2_evidence]
    report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT / 'src').rglob('*.mojo'))}
    for binary in args.binary:
        binary = binary.resolve()
        report['binaries'].append(dict(path=str(binary), sha256=hashlib.sha256(binary.read_bytes()).hexdigest()))
        for entry in json.loads((OUT / 'controls.json').read_text()):
            path = Path(entry['path'])
            assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256']
            if entry['valid']:
                parity = compare(path, binary)
                assert parity['native'] == 'pass', parity
                outcome = parity
            else:
                proc = subprocess.run([str(binary), str(path)], capture_output=True, text=True)
                assert proc.returncode != 0, entry
                outcome = dict(native='rejected', returncode=proc.returncode, error=proc.stderr + proc.stdout)
            report['controls'].append(dict(path=str(path), sha256=entry['sha256'], binary=str(binary),
                format_valid=entry.get('format_valid', entry['valid']), expected_native=entry.get('expected_native'), outcome=outcome))
        for path, projection in cases:
            evidence = [p for p in page_evidence(path) if any(p['path'][:len(parts)] == parts for parts in projection)]
            assert evidence, (path, projection)
            result = compare(path, binary, projection)
            report['projections'].append(dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), binary=str(binary), projection=projection, pages=evidence, parity=result))
            assert result['native'] == 'pass', result
        for path, components, reason in rejected:
            p = subprocess.run([str(binary), str(path), *components], capture_output=True, text=True)
            report['rejections'].append(dict(path=str(path), binary=str(binary), components=components, reason=reason, returncode=p.returncode, error=p.stderr + p.stdout))
            assert p.returncode != 0, (path, components, reason)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'projection-parity.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"{len(report['projections'])} complete projection comparisons; {len(report['rejections'])} expected rejections; {len(report['controls'])} control checks")


if __name__ == '__main__':
    main()
