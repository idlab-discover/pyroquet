"""Bootstrap must preserve existing oracle environments."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('bootstrap', Path(__file__).resolve().parents[2] / 'tools/bootstrap.py')
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def test_existing_oracle_mismatch_never_runs_installer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requirements = root / 'tests/oracle-requirements.txt'
            requirements.parent.mkdir(); requirements.write_text('example==1.2.3\n')
            oracle = root / 'build/oracle-uv'; (oracle / 'bin').mkdir(parents=True)
            (oracle / 'bin/python').write_text('sentinel')
            actual = dict(python='3.12.13', packages={'example': '9.9.9'})
            with patch.object(bootstrap.subprocess, 'check_output', return_value=json.dumps(actual)), patch.object(bootstrap, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'left unchanged'):
                    bootstrap.prepare_oracle(root, 'unused')
                run.assert_not_called()
            self.assertEqual((oracle / 'bin/python').read_text(), 'sentinel')

    def test_existing_exact_oracle_is_verified_without_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requirements = root / 'tests/oracle-requirements.txt'
            requirements.parent.mkdir(); requirements.write_text('example==1.2.3\n')
            oracle = root / 'build/oracle-uv'; (oracle / 'bin').mkdir(parents=True)
            (oracle / 'bin/python').write_text('sentinel')
            actual = dict(python='3.12.13', packages={'example': '1.2.3'})
            with patch.object(bootstrap.subprocess, 'check_output', return_value=json.dumps(actual)), patch.object(bootstrap, 'run') as run:
                self.assertEqual(bootstrap.prepare_oracle(root, 'unused'), actual)
                run.assert_not_called()

    def test_exact_tool_version_is_required(self):
        with patch.object(bootstrap.subprocess, 'check_output', return_value='uv 0.12.9 (build)'):
            with self.assertRaisesRegex(RuntimeError, 'expected version 0.12.10'):
                bootstrap.tool_version('uv', '0.12.10')


if __name__ == '__main__':
    unittest.main()
