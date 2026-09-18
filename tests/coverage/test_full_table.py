"""Export/parity regressions, run with the retained oracle Python environment."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import json

import pyarrow as pa
import pyarrow.parquet as pq

spec = importlib.util.spec_from_file_location('full_table', Path(__file__).with_name('full_table.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FullTableTests(unittest.TestCase):
    def test_export_names_null_empty_binary_and_float_bits(self):
        table = module.parse_native('2 2\n610a62\n12 1 0\nx\nnull\n66\n9 0 0\n2147483648\n2143289345\n')
        self.assertEqual(table['columns'][0]['name'], 'a\nb')
        self.assertEqual(table['columns'][0]['values'], ['', None])
        self.assertEqual(table['columns'][1]['values'], [2147483648, 2143289345])

    def test_complete_mixed_table(self):
        binary = module.ROOT / 'build/coverage-ledger/read-table'
        self.assertTrue(binary.exists(), 'Build the reader first')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.parquet'
            schema = pa.schema([pa.field('i', pa.int32(), False), pa.field('bytes', pa.binary()),
                                pa.field('flag', pa.bool_()), pa.field('float', pa.float32(), False)])
            table = pa.Table.from_arrays([pa.array([1, -2, 3], pa.int32()), pa.array([b'', None, b'\x00\xff']),
                                         pa.array([True, None, False]), pa.array([-0., 1.25, float('inf')], pa.float32())], schema=schema)
            pq.write_table(table, path, compression='NONE', use_dictionary=False)
            result = module.inspect_full_table(path, binary, Path(directory) / 'output')
            self.assertEqual(result['native']['status'], 'exported', result)
            for oracle, outcome in result['oracles'].items():
                self.assertEqual(outcome['status'], 'pass', (oracle, outcome))

    def test_null_nan_oracle_limitation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'nan.parquet'
            pq.write_table(pa.table({'f': pa.array([None, float('nan')], pa.float64())}), path,
                           compression='NONE', use_dictionary=False)
            _, limitations = module._fastparquet_export(path)
            self.assertTrue(limitations)

    def test_native_rejection_does_not_claim_oracle_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            result = module.inspect_full_table(Path(directory) / 'bad.parquet', module.ROOT / 'build/coverage-ledger/read-table', directory)
            self.assertEqual(result['native']['status'], 'error')
            self.assertEqual({item['status'] for item in result['oracles'].values()}, {'not_exercised'})

    def test_fixed_binary_width_is_not_silently_erased(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixed.parquet'
            pq.write_table(pa.table({'f': pa.array([b'\x00\xff', None], pa.binary(2))}), path,
                           compression='NONE', use_dictionary=False)
            result = module.inspect_full_table(path, module.ROOT / 'build/coverage-ledger/read-table',
                                               Path(directory) / 'output')
            self.assertEqual(result['native']['status'], 'exported', result)
            self.assertEqual(result['oracles']['pyarrow']['status'], 'pass', result)
            self.assertEqual(result['oracles']['duckdb']['status'], 'limitation', result)
            self.assertEqual(result['oracles']['duckdb']['comparison_result']['status'], 'mismatch', result)

    def test_timeout_preserves_partial_streams(self):
        with patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired(
                ['reader'], 120, output=b'partial', stderr=b'waiting')):
            result = module._run(['reader'])
        self.assertEqual(result['status'], 'timeout')
        self.assertEqual(result['stdout'], 'partial')
        self.assertEqual(result['stderr'], 'waiting')

    def test_changed_binary_is_not_exercised(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'reader'
            binary.write_bytes(b'changed binary')
            provenance = json.loads((module.ROOT / 'build/coverage-ledger/read-table.build.json').read_text())
            binary.with_suffix('.build.json').write_text(json.dumps(provenance))
            result = module.inspect_full_table(Path(directory) / 'input', binary, directory)
            self.assertEqual(result['native']['status'], 'provenance_error')
            self.assertEqual({item['status'] for item in result['oracles'].values()}, {'not_exercised'})

    def test_mismatch_detects_row_order_and_type(self):
        table = module.parse_native('2 1\n69\n6 0 0\n1\n2\n')
        reordered = module.parse_native('2 1\n69\n6 0 0\n2\n1\n')
        self.assertEqual(module.compare_tables(table, reordered)['status'], 'mismatch')


if __name__ == '__main__':
    unittest.main()
