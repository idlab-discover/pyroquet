"""Targeted byte-probe checks; run with the development oracle environment."""
from pathlib import Path
import tempfile
import unittest

from page_evidence import _levels, inspect_page_evidence
from replay_page_adjudication import ROOT, SOURCES, corrected_bytes


class WidthOneLevelEvidenceTests(unittest.TestCase):
    def test_exact_repeated_present_and_null_runs(self):
        runs, present = _levels(bytes.fromhex("06010400"), 5)
        self.assertEqual(present, 3)
        self.assertEqual([run["count"] for run in runs], [3, 2])

    def test_final_packed_group_counts_only_declared_values(self):
        # Three logical levels 1,0,1; trailing bits are not logical values.
        runs, present = _levels(bytes.fromhex("0305"), 3)
        self.assertEqual(present, 2)
        self.assertEqual(runs, [{"kind": "packed", "count": 8}])

    def test_repeated_overrun_retained_as_evidence(self):
        runs, present = _levels(bytes.fromhex("82800101"), 8192)
        self.assertEqual(present, 8192)
        self.assertEqual(runs, [{"kind": "rle", "count": 8193, "value": 1}])

    def test_truncated_and_malformed_streams_are_errors(self):
        for data, count in [
            (b"\x80", 1),                 # Unterminated ULEB128.
            (b"\x80" * 6, 1),             # Oversized header.
            (b"\x02", 1),                 # Missing repeated value.
            (b"\x02\x02", 1),             # Value outside width one.
            (b"\x03", 1),                 # Missing packed byte.
            (b"\x05\xff", 9),             # Incomplete second packed byte.
            (b"\x00\x01", 1),             # Zero repeated run.
            (b"\x01", 1),                 # Zero packed run.
            (b"\x02\x01", 2),             # Too few declared levels.
            (b"\x80\x80\x80\x80\x10\x01", 1),  # RLE length 2**31.
            (b"", -1),
        ]:
            with self.subTest(data=data, count=count):
                with self.assertRaises(ValueError):
                    _levels(data, count)

    def test_unknown_path_is_not_a_validity_pass(self):
        result = inspect_page_evidence("not-a-target.parquet")
        self.assertEqual(result["status"], "not_targeted")
        self.assertEqual(result["inspected_pages"], 0)


class RetainedPageEvidenceTests(unittest.TestCase):
    def test_padding_rejection_and_surgical_controls(self):
        corpus = ROOT.parent / "fastparquet/test-data"
        with tempfile.TemporaryDirectory() as directory:
            for name in SOURCES:
                with self.subTest(name=name):
                    source = corpus / name
                    raw = source.read_bytes()
                    original = inspect_page_evidence(source)
                    if name.startswith("customer"):
                        self.assertEqual(original["status"], "unresolved_disagreement")
                        self.assertEqual(len(original["findings"]), 45)
                        self.assertEqual(original["inspected_pages"], 48)
                    else:
                        self.assertEqual(original["status"], "invalid_fixture")
                        finding = original["findings"][0]
                        self.assertEqual(finding["plain_actual_bytes"], 16)
                        self.assertEqual(finding["plain_expected_bytes"], 8)
                        self.assertEqual(finding["surplus_bytes_hex"], "00" * 8)
                    target = Path(directory) / name
                    target.write_bytes(corrected_bytes(source, raw, original))
                    corrected = inspect_page_evidence(target)
                    self.assertEqual(corrected["status"], "no_targeted_anomaly")
                    self.assertEqual(corrected["findings"], [])
                    self.assertEqual(corrected["inspected_pages"], original["inspected_pages"])
                    self.assertEqual(source.read_bytes(), raw)

    def test_unknown_source_bytes_cannot_be_corrected(self):
        with self.assertRaisesRegex(ValueError, "pinned source hash"):
            corrected_bytes(Path("customer.impala.parquet"), b"arbitrary", {})


if __name__ == "__main__":
    unittest.main()
