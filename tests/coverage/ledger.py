"""Evidence ledger for the complete local golden corpus (development only).

Never interprets a successful open, an exclusion, or an oracle skip as parity.
Run with the pinned oracle Python; see README.md in this directory.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ORACLES = ('pyarrow', 'duckdb', 'fastparquet')
EXCLUSIONS = Path(__file__).with_name('excluded_fixtures.json')


def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def revision(path):
    result = subprocess.run(['git', '-C', str(path), 'rev-parse', 'HEAD'],
                            capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def artifact(path):
    path = Path(path)
    return {'path': str(path.resolve()), 'sha256': digest(path), 'bytes': path.stat().st_size}


def discover(corpus):
    """Magic-based selection includes extensionless files and summary metadata."""
    result = []
    for path in sorted(Path(corpus).rglob('*')):
        if path.is_file():
            with path.open('rb') as f:
                if f.read(4) == b'PAR1':
                    result.append(path)
    return result


def fixture_exclusion(relative, sha256, exclusions):
    """A repaired or replaced fixture must not inherit an old exclusion."""
    match = exclusions.get(relative)
    return match if match and match['sha256'] == sha256 else None


def excluded_record(relative, path, old, exclusion):
    skipped = {'status': 'not_exercised', 'reason': 'excluded_invalid_fixture'}
    return {'id': relative, 'role': 'standalone_file', 'fixture': artifact(path),
            'selection': {'status': 'excluded_invalid_fixture', 'exclusion': exclusion},
            'historical': historical_outcomes(old, exclusion['sha256']),
            'adjudication': {'status': 'invalid_fixture', 'findings': exclusion['evidence'],
                             'source': 'retained_exclusion_record; not reinvestigated'},
            'footer': skipped.copy(), 'observed_features': [],
            'numeric_replay': skipped.copy(),
            'full_table': {'native': skipped.copy(),
                           'oracles': {engine: skipped.copy() for engine in ORACLES}},
            'write': skipped.copy()}


def load_history(directory):
    if directory is None:
        return {}, {'status': 'not_available'}
    directory = Path(directory)
    needed = ('inventory.json', 'manifest.json', 'results.json', 'identity.json')
    if not all((directory / name).is_file() for name in needed):
        raise ValueError('Historical directory is incomplete; omit --historical to run without it')
    inventory, manifest, results, identity = (
        json.loads((directory / name).read_text()) for name in needed)
    by_id = {x['id']: x for x in results}
    by_path = {x['path']: x for x in manifest if x['corpus'] == 'golden'}
    records = {}
    for original in inventory:
        if original['corpus'] != 'golden':
            continue
        path = original['path']
        selected = by_path.get(path)
        row = {'inventory': original, 'manifest': selected,
               'result': by_id.get(selected['id']) if selected else None}
        if selected:
            row['evidence_files'] = [artifact(p) for p in sorted((directory / 'logs').glob(f"{selected['id']:03}-*")) if p.is_file()]
            log = directory / 'logs' / f"{selected['id']:03}-next-time.stdout"
            if log.exists():
                row['native_log'] = artifact(log)
                text = log.read_text()
                marker = 'Unhandled exception caught during execution: '
                row['native_error'] = text.split(marker, 1)[1].strip() if marker in text else None
        records[path] = row
    return records, {'status': 'available', 'artifacts': [artifact(directory / n) for n in needed],
                     'identity': identity, 'directory': str(directory.resolve())}


def historical_outcomes(history, current_sha):
    """Retain original results even if bytes changed, but never promote them."""
    if history is None:
        return {'status': 'not_exercised', 'reason': 'No historical corpus entry'}
    selected = history['manifest']
    if selected is None:
        return {'status': 'not_exercised', 'reason': history['inventory'].get('reason'),
                'fixture_identity': 'historical_hash_unavailable', 'scope': 'numeric_projection'}
    fresh = selected['sha256'] == current_sha
    result = history['result']
    record = {'status': 'recorded' if fresh else 'stale_fixture',
              'fixture_identity': 'sha256_match' if fresh else 'sha256_mismatch',
              'expected_sha256': selected['sha256'], 'scope': 'numeric_projection',
              'selected_names': selected['selected_names'], 'expected_types': selected['types'],
              'case': selected['case'], 'original_result': result,
              'native_error': history.get('native_error'), 'native_log': history.get('native_log'),
              'evidence_files': history.get('evidence_files', []),
              'comparisons': {}}
    if result is None:
        record['status'] = 'not_exercised'
        record['reason'] = 'No completed historical result'
        return record
    for engine in ('next', *ORACLES):
        raw = result['engines'].get(engine, {}) if engine in ('next', 'pyarrow') else result.get('oracles', {}).get(engine, {})
        comparison = raw.get('validation', raw)
        if not fresh:
            status = 'stale_fixture'
        elif comparison.get('exact_match') is True:
            status = 'reference' if engine == 'pyarrow' else 'pass'
        elif comparison.get('returncode', raw.get('returncode')) not in (None, 0):
            status = 'error'
        elif comparison.get('exact_match') is False:
            status = 'mismatch'
        else:
            status = 'not_exercised'
        record['comparisons'][engine] = {'status': status, 'evidence': raw}
    return record


def footer_inventory(path):
    """Schema and declared layout; null statistics are explicitly not observations."""
    import fastparquet
    import pyarrow.parquet as pq
    result = {'status': 'inspected', 'engines': {}}
    try:
        pf = fastparquet.ParquetFile(path)
        tt = fastparquet.parquet_thrift
        def enum(e, x):
            return None if x is None else e._VALUES_TO_NAMES.get(x, f'UNKNOWN_{x}')
        result['engines']['fastparquet'] = {'status': 'inspected'}
        result['writer'] = str(pf.fmd.created_by)
        result['footer_rows'] = pf.fmd.num_rows
        result['schema'] = [dict(name=n.name, physical=enum(tt.Type, n.type),
                                 repetition=enum(tt.FieldRepetitionType, n.repetition_type),
                                 children=n.num_children, fixed_width=n.type_length,
                                 converted=enum(tt.ConvertedType, n.converted_type),
                                 logical=str(n.logicalType) if n.logicalType is not None else None,
                                 precision=n.precision, scale=n.scale, field_id=n.field_id)
                            for n in pf.fmd.schema]
        result['chunks'] = []
        for g, group in enumerate(pf.row_groups):
            for c, chunk in enumerate(group.columns):
                m = chunk.meta_data
                if m is None:
                    result['chunks'].append({'row_group': g, 'column': c, 'status': 'missing_metadata'})
                    continue
                result['chunks'].append(dict(row_group=g, column=c, path=m.path_in_schema,
                    codec=enum(tt.CompressionCodec, m.codec), physical=enum(tt.Type, m.type),
                    declared_encodings=[enum(tt.Encoding, e) for e in m.encodings],
                    compressed_bytes=m.total_compressed_size, uncompressed_bytes=m.total_uncompressed_size,
                    num_values=m.num_values, row_group_rows=group.num_rows,
                    statistics_null_count=m.statistics.null_count if m.statistics else None,
                    null_count_evidence='footer_declaration_not_decoded', external_file=chunk.file_path))
    except Exception as exc:
        result['status'] = 'partial_inspection'
        result['engines']['fastparquet'] = {'status': 'error', 'error': repr(exc)}
    try:
        pf = pq.ParquetFile(path)
        result['engines']['pyarrow'] = {'status': 'inspected', 'rows': pf.metadata.num_rows,
                                       'schema': str(pf.schema), 'arrow_schema': str(pf.schema_arrow)}
    except Exception as exc:
        result['status'] = 'partial_inspection'
        result['engines']['pyarrow'] = {'status': 'error', 'error': repr(exc)}
    return result


def feature_observations(footer):
    """Presence only, not support claims; report distinct combinations as well as files."""
    features = set()
    for c in footer.get('chunks', []):
        if 'codec' in c:
            features.add('codec:' + c['codec'])
            features.add('physical:' + c['physical'])
    for n in footer.get('schema', []):
        if n['converted']:
            features.add('converted:' + n['converted'])
        if n['repetition'] == 'REPEATED':
            features.add('shape:repeated')
    return sorted(features)


def first_blocker(history):
    error = history.get('native_error') or ''
    if error == 'Only UNCOMPRESSED and SNAPPY columns are supported':
        return {'status': 'implementation_gap', 'feature': 'codec', 'error': error,
                'scope': 'historical_numeric_first_blocker', 'validity': 'not_established'}
    if error == 'Unsupported numeric data encoding':
        return {'status': 'implementation_gap', 'feature': 'encoding', 'error': error,
                'scope': 'historical_numeric_first_blocker', 'validity': 'not_established'}
    if error == 'Selected field is not a supported flat column':
        return {'status': 'implementation_gap', 'feature': 'scalar_logical_or_nested_type',
                'error': error, 'scope': 'historical_numeric_first_blocker', 'validity': 'not_established'}
    if error:
        return {'status': 'unresolved_disagreement', 'error': error,
                'scope': 'historical_numeric_first_blocker'}
    return {'status': 'not_exercised', 'scope': 'adjudication',
            'reason': 'No rejected case requiring adjudication recorded here'}


def replay_numeric(path, history, historical_dir, out):
    selected = history['manifest']
    if not selected:
        return {'status': 'not_exercised', 'reason': 'Not selected historically'}
    if digest(path) != selected['sha256']:
        return {'status': 'stale_fixture', 'reason': 'Refusing to compare changed fixture with historical digest'}
    identity = json.loads((historical_dir / 'identity.json').read_text())
    binary = historical_dir / 'next-load'
    if not binary.is_file() or digest(binary) != identity.get('files', {}).get('next-load'):
        return {'status': 'stale_binary', 'reason': 'Historical executable hash unavailable or changed'}
    out.mkdir(parents=True, exist_ok=True)
    export = out / 'numeric.bin'
    command = [str(binary.resolve()), str(path.resolve()), str(export.resolve()), '0', *selected['selected_names']]
    try:
        p = subprocess.run(command, capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        return {'status': 'timeout', 'command': command}
    (out / 'stdout').write_bytes(p.stdout)
    (out / 'stderr').write_bytes(p.stderr)
    record = {'status': 'error' if p.returncode else 'not_compared', 'returncode': p.returncode,
              'command': command, 'binary': artifact(binary), 'scope': 'numeric_projection',
              'reference_age': 'historical_hash_verified_fixture',
              'logs': [artifact(out / 'stdout'), artifact(out / 'stderr')]}
    if not p.returncode:
        if not export.is_file():
            record.update(status='error', error='Native succeeded without export')
        else:
            record['export'] = artifact(export)
            ref = (history['result'] or {}).get('expected_sha256')
            record['status'] = 'pass' if ref and digest(export) == ref else 'mismatch' if ref else 'not_compared'
            record['expected_sha256'] = ref
    return record


def adjudicate(record):
    """Keep independent findings; an invalid fixture can also need a codec."""
    findings = []
    first = record['adjudication']
    if first['status'] != 'not_exercised':
        findings.append(first)
    metadata = record.get('metadata_evidence', {})
    for finding in metadata.get('findings', []):
        if record.get('role') == 'dataset_summary' and finding.get('reason') == 'external column chunk':
            findings.append(dict(finding, status='not_exercised', evidence='metadata_evidence'))
            continue
        findings.append(dict(finding, status='invalid_fixture' if finding['disposition'] == 'confirmed_invalid_metadata' else 'unresolved_disagreement',
                             evidence='metadata_evidence'))
    for finding in record.get('page_evidence', {}).get('findings', []):
        findings.append(dict(finding, status=finding['adjudication_status'], evidence='page_evidence'))
    for finding in record.get('nation_evidence', {}).get('findings', []):
        findings.append(dict(finding, evidence='nation_evidence'))
    statuses = {f['status'] for f in findings}
    # Invalidity is an established violation, not an assertion that every other
    # field is valid. Keep unresolved findings and implementation gaps alongside it.
    disposition = next((s for s in ('invalid_fixture', 'unresolved_disagreement', 'implementation_gap') if s in statuses), 'not_adjudicated')
    if first['status'] == 'unresolved_disagreement' and any(f.get('evidence') for f in findings):
        # The historical error is a symptom, not an extra independent question.
        findings[0] = dict(findings[0], status='observed_rejection')
        statuses = {f['status'] for f in findings}
        disposition = next((s for s in ('invalid_fixture', 'unresolved_disagreement', 'implementation_gap') if s in statuses), 'not_adjudicated')
    return {'status': disposition, 'findings': findings,
            'validity_scope': 'Only listed rules adjudicated; no general validity pass'}


def actual_page_features(record):
    combinations = Counter()
    incomplete = 0
    for group in record.get('metadata_evidence', {}).get('row_groups', []):
        for c, column in enumerate(group['columns']):
            scan = column['page_scan']
            incomplete += scan['status'] != 'complete'
            chunk = next((x for x in record['footer'].get('chunks', [])
                          if x['row_group'] == group['index'] and x['column'] == c), {})
            for page in scan.get('page_records', []):
                detail = page.get('data_page_header', page.get('data_page_header_v2'))
                if detail is None:
                    continue
                key = (chunk.get('physical'), chunk.get('codec'), page['type'], detail['encoding'])
                combinations[key] += 1
    return {'combinations': [dict(physical=k[0], codec=k[1], page_type=k[2], encoding=k[3], pages=v)
                             for k, v in combinations.items()],
            'incomplete_chunk_scans': incomplete,
            'scope': 'Page headers, not decoded null density or body validity'}


def summarize(records):
    inventory = records
    records = [r for r in inventory if r.get('selection', {}).get('status') != 'excluded_invalid_fixture']
    return {'files': len(inventory),
            'excluded_invalid_fixtures': len(inventory) - len(records),
            'active_files': len(records),
            'active_standalone_files': sum(r['role'] == 'standalone_file' for r in records),
            'file_bytes': sum(r['fixture']['bytes'] for r in inventory),
            'roles': dict(Counter(r['role'] for r in records)),
            'historical_native': dict(Counter(r['historical'].get('comparisons', {}).get('next', {}).get('status', 'not_exercised') for r in records)),
            'adjudications': dict(Counter(r['adjudication']['status'] for r in records)),
            'observed_features_by_file': dict(Counter(f for r in records for f in r['observed_features'])),
            'full_table_all_three_pass': sum(all(r['full_table']['oracles'][e]['status'] == 'pass' for e in ORACLES) for r in records),
            'full_table_oracles': {e: dict(Counter(r['full_table']['oracles'][e]['status'] for r in records)) for e in ORACLES},
            'full_table_native': dict(Counter(r['full_table'].get('native', {}).get('status', 'not_exercised') for r in records)),
            'warning': 'Counts are scoped evidence, not a format-compliance percentage. Skips and limitations are not passes.'}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--corpus', type=Path, default=ROOT.parent / 'fastparquet/test-data')
    ap.add_argument('--historical', type=Path)
    ap.add_argument('--out', type=Path, default=ROOT / 'build/coverage-ledger')
    ap.add_argument('--replay-numeric', action='store_true')
    ap.add_argument('--full-table-binary', type=Path)
    ap.add_argument('--preserve-fixtures', action='store_true')
    args = ap.parse_args()
    args.corpus = args.corpus.resolve()
    args.out = args.out.resolve()
    if not args.corpus.is_dir():
        ap.error('Corpus directory does not exist')
    if args.replay_numeric and args.historical is None:
        ap.error('--replay-numeric requires --historical')
    tool_paths = sorted([*Path(__file__).parent.glob('*.py'), *Path(__file__).parent.glob('*.mojo')])
    tool_paths.append(EXCLUSIONS)
    tool_sources = [artifact(p) for p in tool_paths]
    exclusions = {f['path']: f for f in json.loads(EXCLUSIONS.read_text())['fixtures']}
    history, provenance = load_history(args.historical)
    paths = discover(args.corpus)
    if not paths:
        ap.error('No PAR1 files found')
    args.out.mkdir(parents=True, exist_ok=True)
    from metadata_evidence import inspect_metadata_evidence
    from page_evidence import inspect_page_evidence
    from nation_evidence import inspect_nation_evidence
    if args.full_table_binary:
        from full_table import inspect_full_table
    reader_provenance = {'status': 'not_exercised'}
    if args.full_table_binary:
        reader_provenance = {'binary': artifact(args.full_table_binary)}
        build_record = args.full_table_binary.with_suffix('.build.json')
        if build_record.is_file():
            built = json.loads(build_record.read_text())
            if built.get('binary_sha256') != digest(args.full_table_binary):
                raise ValueError('Reader binary differs from build provenance')
            changed = [p for p, sha in built.get('source_hashes', {}).items() if not Path(p).is_file() or digest(p) != sha]
            if changed:
                raise ValueError(f'Reader source/dependencies changed since build: {changed}')
            reader_provenance['build'] = artifact(build_record)
            reader_provenance['status'] = 'source_and_binary_hashes_match'
        else:
            reader_provenance['status'] = 'build_provenance_unavailable'
    records = []
    for number, path in enumerate(paths):
        relative = path.relative_to(args.corpus).as_posix()
        original_sha = digest(path)
        exclusion = fixture_exclusion(relative, original_sha, exclusions)
        if exclusion:
            records.append(excluded_record(relative, path, history.get(str(path)), exclusion))
            print(f'{number+1}/{len(paths)} EXCLUDED {relative}', flush=True)
            (args.out / 'progress.json').write_text(json.dumps({'complete': False, 'files': records}, indent=2) + '\n')
            continue
        case_out = args.out / 'cases' / relative
        case_out.mkdir(parents=True, exist_ok=True)
        role = 'dataset_summary' if path.name in ('_metadata', '_common_metadata') else 'standalone_file'
        old = history.get(str(path))
        rec = {'id': relative, 'role': role, 'selection': {'status': 'active'}, 'fixture': artifact(path),
               'historical': historical_outcomes(old, original_sha),
               'footer': footer_inventory(path), 'adjudication': first_blocker(old or {}),
               'full_table': {'native': {'status': 'not_exercised'},
                              'oracles': {e: {'status': 'not_exercised'} for e in ORACLES}},
               'write': {'status': 'not_exercised', 'reason': 'Read-corpus ledger; no writer claim'}}
        if rec['historical']['status'] == 'stale_fixture':
            rec['adjudication'] = {'status': 'not_exercised', 'reason': 'Historical fixture hash mismatch'}
        rec['observed_features'] = feature_observations(rec['footer'])
        for name, inspector in [('metadata_evidence', inspect_metadata_evidence), ('page_evidence', inspect_page_evidence), ('nation_evidence', inspect_nation_evidence)]:
            try:
                rec[name] = inspector(path)
            except Exception as exc:
                rec[name] = {'status': 'inspection_error', 'error': repr(exc)}
        rec['actual_pages'] = actual_page_features(rec)
        if args.preserve_fixtures:
            preserved = args.out / 'fixtures' / relative
            preserved.parent.mkdir(parents=True, exist_ok=True)
            if preserved.exists() and digest(preserved) != original_sha:
                raise ValueError(f'Refusing to overwrite preserved fixture: {preserved}')
            if not preserved.exists():
                shutil.copyfile(path, preserved)
            rec['preserved_fixture'] = artifact(preserved)
        if args.replay_numeric and old:
            rec['numeric_replay'] = replay_numeric(path, old, args.historical, case_out / 'numeric')
        if args.full_table_binary and role == 'standalone_file':
            rec['full_table'] = inspect_full_table(path, args.full_table_binary, case_out / 'full-table')
        elif role == 'dataset_summary':
            rec['full_table']['reason'] = 'Dataset metadata is not a standalone load fixture'
        native = rec['full_table']['native']
        if native.get('status') == 'error':
            message = native.get('error', '')
            marker = 'Unhandled exception caught during execution: '
            error = message.split(marker, 1)[-1].strip()
            fresh = first_blocker({'native_error': error}) if error else {'status': 'unresolved_disagreement', 'error': 'Native export failed; see retained logs'}
            fresh['scope'] = 'fresh_full_table_first_blocker'
            rec['full_table']['first_blocker'] = fresh
            if rec['adjudication']['status'] == 'not_exercised':
                rec['adjudication'] = fresh
        rec['adjudication'] = adjudicate(rec)
        if rec['full_table'].get('first_blocker') and rec['full_table']['first_blocker'] not in rec['adjudication']['findings']:
            rec['adjudication']['findings'].append(rec['full_table']['first_blocker'])
        if digest(path) != original_sha:
            raise ValueError(f'Fixture changed during inspection: {path}')
        records.append(rec)
        print(f'{number+1}/{len(paths)} {relative}', flush=True)
        # Durable checkpoint: an interrupted run remains explicitly incomplete.
        (args.out / 'progress.json').write_text(json.dumps({'complete': False, 'files': records}, indent=2) + '\n')
    disappeared = sorted(set(history) - {str(p) for p in paths})
    spec = ROOT.parent / 'parquet-format'
    if tool_sources != [artifact(p) for p in tool_paths]:
        raise ValueError('Coverage tool sources changed during the run; repeat with stable inputs')
    result = {'format_version': 1, 'complete': True, 'created_utc': datetime.now(timezone.utc).isoformat(),
              'scope': 'golden_single_file_read_coverage',
              'provenance': {'repository_revision': revision(ROOT), 'corpus_revision': revision(args.corpus),
                             'spec_revision': revision(spec),
                             'spec_files': [artifact(spec / n) for n in ('README.md', 'Encodings.md', 'Compression.md', 'LogicalTypes.md', 'src/main/thrift/parquet.thrift')],
                             'versions': {e: importlib.metadata.version(e) for e in (*ORACLES, 'pandas', 'numpy', 'thrift')},
                             'historical': provenance, 'full_table_reader': reader_provenance,
                             'tool_sources': tool_sources},
              'missing_historical_entries': disappeared, 'summary': summarize(records), 'files': records}
    (args.out / 'ledger.json').write_text(json.dumps(result, indent=2) + '\n')
    (args.out / 'progress.json').unlink()
    print(json.dumps(result['summary'], indent=2))


if __name__ == '__main__':
    main()
