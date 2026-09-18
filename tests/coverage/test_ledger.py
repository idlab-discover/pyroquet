"""Evidence bookkeeping regressions: stale/skipped results must not become passes."""
import copy
import tempfile
from pathlib import Path
import unittest

from ledger import adjudicate, discover, historical_outcomes, actual_page_features, fixture_exclusion, excluded_record, summarize


class LedgerTests(unittest.TestCase):
    def history(self):
        return {'inventory': {}, 'manifest': {'sha256': 'original', 'selected_names': ['a'],
            'types': ['int64'], 'case': 'golden/a'}, 'result': {
            'engines': {'next': {'validation': {'exact_match': True, 'returncode': 0}},
                        'pyarrow': {'validation': {'exact_match': True, 'returncode': 0}}},
            'oracles': {'duckdb': {'returncode': 1}, 'fastparquet': {'exact_match': False, 'returncode': 0}}}}

    def test_exclusion_requires_matching_path_and_hash(self):
        record = {'path': 'bad.parquet', 'sha256': 'old', 'evidence': []}
        exclusions = {'bad.parquet': record}
        self.assertEqual(fixture_exclusion('bad.parquet', 'old', exclusions), record)
        self.assertIsNone(fixture_exclusion('bad.parquet', 'repaired', exclusions))
        self.assertIsNone(fixture_exclusion('other.parquet', 'old', exclusions))
        self.assertIsNone(fixture_exclusion('customer.impala.parquet', 'old', exclusions))

    def test_excluded_historical_pass_is_not_active_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'bad.parquet'
            path.write_bytes(b'PAR1')
            record = excluded_record('bad.parquet', path, self.history(),
                                     {'sha256': 'original', 'evidence': []})
            self.assertEqual(record['historical']['comparisons']['next']['status'], 'pass')
            self.assertEqual(record['full_table']['native']['status'], 'not_exercised')
            summary = summarize([record])
            self.assertEqual(summary['excluded_invalid_fixtures'], 1)
            self.assertEqual(summary['active_files'], 0)
            self.assertEqual(summary['historical_native'], {})
            self.assertEqual(summary['full_table_all_three_pass'], 0)

    def test_oracle_failures_survive_successful_native(self):
        result = historical_outcomes(self.history(), 'original')
        self.assertEqual({k: v['status'] for k, v in result['comparisons'].items()},
                         {'next': 'pass', 'pyarrow': 'reference', 'duckdb': 'error', 'fastparquet': 'mismatch'})

    def test_changed_fixture_invalidates_every_historical_pass(self):
        result = historical_outcomes(self.history(), 'changed')
        self.assertEqual(result['status'], 'stale_fixture')
        self.assertEqual({v['status'] for v in result['comparisons'].values()}, {'stale_fixture'})
        self.assertTrue(result['original_result']['engines']['next']['validation']['exact_match'])

    def test_exclusion_and_missing_comparison_never_pass(self):
        excluded = {'inventory': {'reason': 'no numeric columns'}, 'manifest': None}
        self.assertEqual(historical_outcomes(excluded, 'x')['status'], 'not_exercised')
        history = self.history()
        history['result']['oracles']['fastparquet'] = {'returncode': 0}
        self.assertEqual(historical_outcomes(history, 'original')['comparisons']['fastparquet']['status'], 'not_exercised')

    def test_discovery_does_not_drop_extensionless_or_malformed_magic_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, content in [('a.parquet', b'PAR1bad'), ('_metadata', b'PAR1summary'),
                                  ('extensionless', b'PAR1'), ('wrong.parquet', b'NOPE')]:
                (root / name).write_bytes(content)
            self.assertEqual({p.name for p in discover(root)}, {'a.parquet', '_metadata', 'extensionless'})

    def test_adjudication_retains_multiple_blockers_and_uncertainty(self):
        record = {'adjudication': {'status': 'implementation_gap', 'feature': 'codec'},
                  'metadata_evidence': {'findings': [
                      {'disposition': 'confirmed_invalid_metadata', 'rule': 'counts'},
                      {'disposition': 'unresolved', 'rule': 'partial_scan'}]}}
        before = copy.deepcopy(record)
        result = adjudicate(record)
        self.assertEqual(record, before)
        self.assertEqual(result['status'], 'invalid_fixture')
        self.assertEqual({f['status'] for f in result['findings']},
                         {'implementation_gap', 'invalid_fixture', 'unresolved_disagreement'})

    def test_observation_is_not_whole_file_validity(self):
        result = adjudicate({'adjudication': {'status': 'not_exercised'}})
        self.assertEqual(result['status'], 'not_adjudicated')

    def test_page_features_use_data_headers_not_footer_encoding_list(self):
        record = {'footer': {'chunks': [{'row_group': 0, 'column': 0, 'physical': 'INT32',
                                        'codec': 'SNAPPY', 'declared_encodings': ['PLAIN', 'RLE']}]},
                  'metadata_evidence': {'row_groups': [{'index': 0, 'columns': [{'page_scan': {
                      'status': 'unresolved', 'page_records': [
                          {'type': 2, 'dictionary_page_header': {'encoding': 0}},
                          {'type': 3, 'data_page_header_v2': {'encoding': 5}}]}}]}]}}
        result = actual_page_features(record)
        self.assertEqual(result['incomplete_chunk_scans'], 1)
        self.assertEqual(result['combinations'], [{'physical': 'INT32', 'codec': 'SNAPPY',
            'page_type': 3, 'encoding': 5, 'pages': 1}])


if __name__ == '__main__':
    unittest.main()
