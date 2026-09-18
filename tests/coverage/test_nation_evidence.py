"""Terminal packed-group controls preserve mandatory padding bytes."""
import unittest
import tempfile
from pathlib import Path

from nation_evidence import inspect_terminal_run, inspect_nation_evidence


class TerminalRunTests(unittest.TestCase):
    def test_untargeted_path_is_not_read_and_changed_source_is_not_adjudicated(self):
        self.assertEqual(inspect_nation_evidence("absent-unrelated.parquet")["status"], "not_targeted")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nation.impala.parquet"
            path.write_bytes(b"changed")
            result = inspect_nation_evidence(path)
            self.assertEqual(result["status"], "not_adjudicated")
            self.assertEqual(result["reason"], "hash_mismatch")
            self.assertEqual(result["findings"], [])

    def test_short_25_value_payload_vs_complete_32_slot_run(self):
        packed = bytes.fromhex("2088418a3928a9c59a7b30ca49abbd18")
        short = inspect_terminal_run(5, 9, packed)
        self.assertFalse(short["packed_run_complete"])
        self.assertEqual(short["missing_packed_bytes"], 4)
        complete = inspect_terminal_run(5, 9, packed + b"\0" * 4)
        self.assertTrue(complete["packed_run_complete"])
        self.assertEqual(complete["missing_packed_bytes"], 0)
        for data in (packed, packed + b"\0" * 4):
            self.assertEqual([(int.from_bytes(data, "little") >> (i * 5)) & 31
                              for i in range(25)], list(range(25)))


if __name__ == "__main__":
    unittest.main()
