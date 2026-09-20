"""Qualification command failures must survive recording and resource collection."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_run', Path(__file__).with_name('run.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GateTests(unittest.TestCase):
    def test_failure_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = module.Gate(Path(directory), {'test': True})
            with self.assertRaisesRegex(RuntimeError, 'exited 7'):
                gate.run('injected', [sys.executable, '-c', 'import sys; print("evidence"); sys.exit(7)'])
            report = json.loads((Path(directory) / 'report.json').read_text())
            step = report['steps'][0]
            self.assertEqual(step['returncode'], 7)
            self.assertEqual(Path(step['stdout']).read_text(), 'evidence\n')
            self.assertGreater(step['resources']['peak_rss_kib'], 0)

    def test_incomplete_oracle_report_cannot_qualify(self):
        for result in ({}, {'status': 'pass', 'unexpected': []},
                       {'status': 'running', 'unexpected': [], 'engines': {}}):
            with self.assertRaises(RuntimeError):
                module.validate_parity(result)

    def test_changed_artifact_invalidates_freeze(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = module.Gate(Path(directory), {})
            artifact = Path(directory) / 'candidate'
            artifact.write_bytes(b'original')
            gate.report['binaries'] = {str(artifact): module.digest(artifact)}
            module.verify_artifacts(gate)
            artifact.write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'frozen artifact changed'):
                module.verify_artifacts(gate)

    def test_success_retains_exact_command_and_output_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = module.Gate(Path(directory), {})
            command = [sys.executable, '-c', 'print("payload")']
            step = gate.run('success', command)
            self.assertEqual(step['command'], command)
            self.assertEqual(step['returncode'], 0)
            self.assertEqual(step['stdout_sha256'], module.digest(step['stdout']))


if __name__ == '__main__':
    unittest.main()
