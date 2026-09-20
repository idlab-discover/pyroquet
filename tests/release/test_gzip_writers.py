"""Reviewed writer errors must match exact identities and independent success."""
import copy
from pathlib import Path
import unittest
from unittest.mock import patch
import gzip_writers


class GzipWriterTests(unittest.TestCase):
    def test_review_requires_all_identity_and_comparison_dimensions(self):
        known = dict(path='case.parquet', sha256='original', version='2026.5.0', error='observed exact failure')
        result = dict(unexpected=[dict(engine='fastparquet', error=known['error'])],
                      engines={name: dict(dimensions=dict(values='pass')) for name in ('pyarrow', 'duckdb')})
        with patch.object(gzip_writers.importlib.metadata, 'version', return_value='2026.5.0'):
            self.assertEqual(gzip_writers.match_review(Path('case.parquet'), 'original', result, [known]), known)
            self.assertIsNone(gzip_writers.match_review(Path('case.parquet'), 'changed', result, [known]))
            self.assertIsNone(gzip_writers.match_review(Path('other.parquet'), 'original', result, [known]))
            changed = copy.deepcopy(result); changed['unexpected'][0]['error'] += ' new'
            self.assertIsNone(gzip_writers.match_review(Path('case.parquet'), 'original', changed, [known]))
            for engine in ('pyarrow', 'duckdb'):
                changed = copy.deepcopy(result); changed['engines'][engine]['dimensions']['values'] = 'see limitations'
                self.assertIsNone(gzip_writers.match_review(Path('case.parquet'), 'original', changed, [known]))
        with patch.object(gzip_writers.importlib.metadata, 'version', return_value='new-version'):
            self.assertIsNone(gzip_writers.match_review(Path('case.parquet'), 'original', result, [known]))


if __name__ == '__main__':
    unittest.main()
