"""Bootstrap must preserve mismatched checkouts and existing oracle environments."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('bootstrap', Path(__file__).resolve().parents[2] / 'tools/bootstrap.py')
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


def repository(path):
    subprocess.run(['git', 'init', '-q', str(path)], check=True)
    (path / 'tracked').write_text('original')
    subprocess.run(['git', '-C', str(path), 'add', 'tracked'], check=True)
    subprocess.run(['git', '-C', str(path), '-c', 'user.name=Bootstrap Test',
                    '-c', 'user.email=bootstrap@example.invalid', '-c', 'commit.gpgsign=false',
                    'commit', '-qm', 'fixture'], check=True)
    return bootstrap.git(path, 'rev-parse', 'HEAD')


class BootstrapTests(unittest.TestCase):
    def test_fetches_exact_revision_into_absent_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); source = base / 'source'; source.mkdir()
            revision = repository(source)
            destination = base / 'dependency'
            result = bootstrap.prepare_dependency(destination, str(source), revision)
            self.assertEqual(result['revision'], revision)
            self.assertEqual((destination / 'tracked').read_text(), 'original')
            with patch.object(bootstrap, 'run') as run:
                bootstrap.prepare_dependency(destination, 'unused', revision)
                run.assert_not_called()

    def test_refuses_wrong_revision_without_modifying_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory); revision = repository(path)
            with patch.object(bootstrap, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'left unchanged'):
                    bootstrap.prepare_dependency(path, 'unused', '0' * 40)
                run.assert_not_called()
            self.assertEqual(bootstrap.git(path, 'rev-parse', 'HEAD'), revision)
            self.assertEqual((path / 'tracked').read_text(), 'original')

    def test_refuses_tracked_changes_without_modifying_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory); revision = repository(path)
            (path / 'tracked').write_text('user changes')
            with self.assertRaisesRegex(RuntimeError, 'tracked modifications'):
                bootstrap.prepare_dependency(path, 'unused', revision)
            self.assertEqual((path / 'tracked').read_text(), 'user changes')

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
