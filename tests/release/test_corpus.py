"""Fail-closed golden fixture identity and release-boundary controls."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import pyarrow as pa
import pyarrow.parquet as pq
import corpus


class CorpusTests(unittest.TestCase):
    def test_inventory_uses_tracked_magic_and_includes_summaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            data = root / 'test-data'; data.mkdir()
            for name, value in [('extensionless', b'PAR1abcd'), ('_metadata', b'PAR1meta'),
                                ('fake.parquet', b'wrong'), ('untracked', b'PAR1extra')]:
                (data / name).write_bytes(value)
            subprocess.run(['git', '-C', str(root), 'add', 'test-data/extensionless',
                            'test-data/_metadata', 'test-data/fake.parquet'], check=True)
            records = corpus.inventory(root)
            self.assertEqual([r['path'] for r in records], ['_metadata', 'extensionless'])
            self.assertEqual(records[0]['sha256'], corpus.digest(data / '_metadata'))

    def test_existing_wrong_checkout_is_never_updated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sentinel = root / 'sentinel'; sentinel.write_text('keep')
            def git(_root, *args):
                if args == ('rev-parse', '--show-toplevel'):
                    return str(root)
                if args == ('rev-parse', 'HEAD'):
                    return 'wrong-revision'
                raise AssertionError(args)
            with patch.object(corpus, 'git', side_effect=git), patch.object(corpus.subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'left unchanged'):
                    corpus.acquire(root)
                run.assert_not_called()
            self.assertEqual(sentinel.read_text(), 'keep')

    def test_declared_type_scope_and_legacy_encoding_footer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input.parquet'
            pq.write_table(pa.table({'list': pa.array([[1, None], None], type=pa.list_(pa.int32()))}), path)
            self.assertEqual(corpus.unsupported(pq.ParquetFile(path)), [])
            pq.write_table(pa.table({'decimal': pa.array([None], type=pa.decimal128(10, 2))}), path)
            self.assertIn('unsupported logical type decimal', corpus.unsupported(pq.ParquetFile(path))[0])

    def test_metadata_review_requires_hash_and_exact_error(self):
        fixture = json.loads(corpus.Path(__file__).with_name('golden_disagreements.json').read_text())['fixtures'][0]
        wrong = dict(path=fixture['path'], sha256='wrong')
        self.assertIsNone(corpus.reviewed_metadata(wrong, None, None, fixture['native_error']))
        self.assertIsNone(corpus.reviewed_metadata(fixture, None, None, 'different error'))


if __name__ == '__main__':
    unittest.main()
