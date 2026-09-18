"""Generated controls distinguish valid declarations from metadata mutations."""
import json
from pathlib import Path
import struct
import tempfile
import unittest

import fastparquet
import pyarrow as pa
import pyarrow.parquet as pq

from metadata_evidence import inspect_metadata_evidence


class MetadataEvidenceTests(unittest.TestCase):
    def test_compressed_total_substitution_and_row_count_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = root / "valid.parquet"
            pq.write_table(pa.table({"id": list(range(1024)), "value": [7] * 1024}),
                           valid, compression="snappy", use_dictionary=False)
            raw = valid.read_bytes()
            evidence = inspect_metadata_evidence(valid)
            self.assertTrue(evidence["footer_rows_match_groups"])
            self.assertEqual(evidence["findings"], [])
            self.assertEqual(evidence["metadata_disposition"], "not_adjudicated")
            group = evidence["row_groups"][0]
            self.assertTrue(group["total_matches_column_uncompressed"])
            self.assertFalse(group["total_matches_column_compressed"])
            self.assertEqual(group["page_totals"]["uncompressed_with_headers"],
                             group["sum_column_uncompressed"])
            self.assertTrue(all(column["page_scan"]["status"] == "complete"
                                for column in group["columns"]))
            json.dumps(evidence)
            footer_start = len(raw) - 8 - struct.unpack("<I", raw[-8:-4])[0]

            def mutated(name, modify):
                metadata = fastparquet.ParquetFile(valid).fmd
                modify(metadata)
                footer = bytes(metadata.to_bytes())
                target = root / name
                target.write_bytes(raw[:footer_start] + footer
                                   + struct.pack("<I", len(footer)) + b"PAR1")
                self.assertEqual(target.read_bytes()[:footer_start], raw[:footer_start])
                return inspect_metadata_evidence(target)

            def compressed_total(metadata):
                metadata.row_groups[0].total_byte_size = group["sum_column_compressed"]

            wrong_bytes = mutated("compressed-total.parquet", compressed_total)
            self.assertEqual([finding["rule"] for finding in wrong_bytes["findings"]],
                             ["row_group_uncompressed_total_matches_columns"])
            self.assertEqual(wrong_bytes["metadata_disposition"], "confirmed_invalid_metadata")
            self.assertTrue(wrong_bytes["row_groups"][0]["total_matches_column_compressed"])

            def wrong_rows(metadata):
                metadata.num_rows += 1

            wrong_count = mutated("wrong-rows.parquet", wrong_rows)
            self.assertEqual([finding["rule"] for finding in wrong_count["findings"]],
                             ["footer_rows_equal_sum_row_group_rows"])
            self.assertFalse(wrong_count["footer_rows_match_groups"])
            self.assertEqual(wrong_count["metadata_disposition"], "confirmed_invalid_metadata")
            self.assertEqual(valid.read_bytes(), raw)


if __name__ == "__main__":
    unittest.main()
