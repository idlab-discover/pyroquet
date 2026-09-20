"""Writer qualification rejects missing cases and unknown oracle failures."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import pyarrow as pa
import pyarrow.parquet as pq
import writer_parity


class WriterGateTests(unittest.TestCase):
    def test_missing_required_output_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with patch.object(writer_parity,'ROOT',root):
                with self.assertRaises(FileNotFoundError):
                    writer_parity.run(root/'binary',root/'evidence')

    def test_unknown_oracle_failure_is_not_a_limitation(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); (root/'build').mkdir()
            name=writer_parity.EXPECTED[0]
            path=root/'build'/name
            schema,rows=writer_parity.expected(path)
            pq.write_table(pa.Table.from_pylist(rows,schema=schema),path)
            result={'unexpected':[{'engine':'fastparquet','error':'new regression'}],
                    'engines':{'pyarrow':{'dimensions':{'values':'pass'}},
                               'duckdb':{'dimensions':{'values':'pass'}}}}
            with patch.object(writer_parity,'ROOT',root), patch.object(writer_parity,'export_native'), patch.object(writer_parity,'compare_export',return_value=result):
                with self.assertRaises(AssertionError):
                    writer_parity.run(root/'binary',root/'evidence')


if __name__=='__main__':unittest.main()
