"""Exact limitation classification must reject nearby unknown reader failures."""
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

from fixtures import options
from list_controls import ERROR, _probe, review_large_list


class ListControlTests(unittest.TestCase):
    def test_required_plain_list_v1_v2_control(self):
        offsets = pa.array(np.arange(65537, dtype=np.int32) * 2)
        child_type = pa.list_(pa.field('element', pa.int32(), False))
        values = pa.ListArray.from_arrays(offsets, pa.array(np.arange(131072, dtype=np.int32)), type=child_type)
        table = pa.Table.from_arrays([values], schema=pa.schema([pa.field('items', child_type, False)]))
        expected = values.to_pylist()
        with TemporaryDirectory() as directory:
            for version in (1, 2):
                path = Path(directory) / f'v{version}.parquet'
                pq.write_table(table, path, **options(0, version, False))
                observed = _probe(path, expected, version)
                self.assertEqual(observed['status'], 'pass' if version == 1 else 'reviewed_reader_error_not_pass')
                if version == 2:
                    self.assertEqual(observed['error'], ERROR)
            with self.assertRaisesRegex(AssertionError, 'every source list value'):
                _probe(Path(directory) / 'v1.parquet', expected[:-1], 1)

    def test_unreviewed_inputs_are_not_classified(self):
        with TemporaryDirectory() as directory:
            out = Path(directory)
            path = out / 'large-mixed-v2-c6.parquet'
            path.write_bytes(b'unreviewed')
            for column, group, error in (('other', 0, ValueError(ERROR)),
                                          ('items', 60, ValueError(ERROR)),
                                          ('items', 0, RuntimeError(ERROR)),
                                          ('items', 0, ValueError('different failure')),
                                          ('items', 0, ValueError(ERROR))):
                self.assertIsNone(review_large_list(path, column, group, error, out))


if __name__ == '__main__':
    unittest.main()
