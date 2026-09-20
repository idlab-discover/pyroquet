"""Prove Mojo test errors escape cleanup in debug and optimized subprocesses."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    base = ROOT / "build/test-reliability"
    base.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="failure-propagation-", dir=base))
    results = []
    for optimization, assertions in (("0", "all"), ("3", "all"), ("3", "none")):
        binary = evidence / f"probe-O{optimization}-{assertions}"
        command = ["pixi", "run", "mojo", "build", f"-O{optimization}",
                   "-D", f"ASSERT={assertions}", "tests/probe_test_failure.mojo", "-o", str(binary)]
        subprocess.run(command, cwd=ROOT, check=True)
        for injected in (False, True):
            run = subprocess.run([str(binary), "--only", "test_injected_failure" if injected else "test_success"],
                                 cwd=ROOT, capture_output=True, text=True)
            record = dict(command=command, injected=injected, returncode=run.returncode,
                          stdout=run.stdout, stderr=run.stderr)
            results.append(record)
            (evidence / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            if (run.returncode != 0) != injected:
                raise AssertionError(record)
            if injected and "injected-test-error" not in run.stdout + run.stderr:
                raise AssertionError(record)
            directories = [line.strip() for line in run.stdout.splitlines()
                           if line.startswith("/tmp/pyroquet-test-")]
            if len(directories) != 1 or any(Path(path).exists() for path in directories):
                raise AssertionError(f"Temporary directory cleanup failed: {record}")
    print(f"PASS: six subprocess cases; evidence: {evidence}")


if __name__ == "__main__":
    main()
