"""Generator contracts: complete hashes, deterministic bounded batches and headers."""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

from fixtures import (identity, generate, sha256, small_flat, small_nested,
                      flat_batch, mixed_batch, describe, options, page_evidence)


class FixtureTests(unittest.TestCase):
    def test_small_types_and_null_locations(self):
        for make in (small_flat, small_nested):
            required = make('required')
            nullable = make('nullable')
            self.assertEqual(len(required), 97)
            self.assertEqual(len(make('empty')), 0)
            for field, column in zip(required.schema, required.columns):
                self.assertFalse(field.nullable)
                self.assertEqual(column.null_count, 0)
            for column in make('allnull').columns:
                self.assertEqual(column.null_count, 97)
            for column in nullable.columns:
                self.assertGreater(column.null_count, 0)
        flat = small_flat('required')
        self.assertEqual(flat['uint64'].to_pylist()[5], 2**64 - 1)
        self.assertEqual(flat['int8'].to_pylist()[2], -128)
        self.assertEqual(flat.schema.field('halffloat').type, pa.float16())

    def test_batch_determinism_and_nested_required_children(self):
        for make in (flat_batch, mixed_batch):
            first = make(np.random.Generator(np.random.PCG64(17)), 63)
            second = make(np.random.Generator(np.random.PCG64(17)), 63)
            self.assertTrue(first.equals(second))
            self.assertTrue(all(not f.nullable for f in first.schema))
        mixed = mixed_batch(np.random.Generator(np.random.PCG64(17)), 63)
        self.assertFalse(mixed.schema.field('items').type.value_field.nullable)
        self.assertEqual(len(mixed['items'].combine_chunks().values), 126)

    def test_page_scanner_is_bounded_and_observes_actual_encodings(self):
        with TemporaryDirectory() as directory:
            for codec in (0, 1, 2, 6):
                for version in (1, 2):
                    path = Path(directory) / f'{codec}-{version}.parquet'
                    settings = options(codec, version, True, small=True)
                    pq.write_table(small_flat('nullable'), path, **settings)
                    # The scanner must never consume an entire path at once.
                    with patch.object(Path, 'read_bytes', side_effect=AssertionError('whole-file read')):
                        actual = page_evidence(path)
                    encodings = actual['encodings']
                    self.assertTrue(any(e['page_version'] == version and e['encoding'] == 8 for e in encodings))
                    self.assertTrue(all(e['codec'] == codec for e in encodings))
                    record = describe(path, 'small', settings, small_flat('nullable').nbytes)
                    self.assertEqual(record['sha256'], sha256(path))
                    self.assertGreater(record['selected_compressed_bytes'], 0)
                    self.assertEqual(record['columns'][0]['null_count'], 14)

    def test_manifest_reuse_rejects_modified_and_stale_files(self):
        with TemporaryDirectory() as directory:
            out = Path(directory)
            file = out / 'control.parquet'
            file.write_bytes(b'control')
            manifest = dict(**identity(), large=False,
                            files=[dict(path=file.name, bytes=7, sha256=sha256(file))])
            manifest_path = out / 'manifest.json'
            manifest_path.write_text(json.dumps(manifest))
            self.assertEqual(generate(out), manifest)
            file.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                generate(out)
            file.write_bytes(b'control')
            manifest['seed'] += 1
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'Stale fixture manifest'):
                generate(out)
        with TemporaryDirectory() as directory:
            (Path(directory) / 'partial').touch()
            with self.assertRaisesRegex(ValueError, 'Partial'):
                generate(Path(directory))


if __name__ == '__main__':
    unittest.main()
