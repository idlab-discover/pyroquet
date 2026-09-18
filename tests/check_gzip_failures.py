"""Inject zlib failures in subprocesses; check lifecycle and public-write cleanup."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/gzip-failures"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--read-only", action="store_true")
    parser.add_argument("--fixture", type=Path,
                        default=ROOT / "build/gzip/v1_required_plain.parquet")
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    fake = BUILD / "fake"
    fake.mkdir(exist_ok=True)
    subprocess.run([os.environ.get("CC", "cc"), "-shared", "-fPIC", "-Wall", "-Wextra",
                    "-Werror", str(ROOT / "tests/gzip_failure_zlib.c"),
                    "-o", str(fake / "libz.so.1")], check=True)
    binary = BUILD / "driver"
    subprocess.run(["pixi", "run", "mojo", "build", "-O3", "-D", "ASSERT=all",
                    "-I", "src", "-I", "../NuMojo", "tests/gzip_failure_driver.mojo",
                    "-o", str(binary)], cwd=ROOT, check=True)
    results = []
    operations = ["read"] if args.read_only else ["read", "write"]
    for operation in operations:
        modes = ["abi", "winapi", "no-gzip", "init-memory", "stream-memory",
                 "no-progress", "data", "end"]
        modes.append("reset" if operation == "read" else "bound")
        for mode in modes:
            with tempfile.TemporaryDirectory(dir=BUILD) as directory:
                audit = BUILD / f"{operation}-{mode}.audit"
                audit.unlink(missing_ok=True)
                env = dict(os.environ, LD_LIBRARY_PATH=str(fake),
                           PYROQUET_TEST_ZLIB_FAILURE=mode,
                           PYROQUET_TEST_ZLIB_AUDIT=str(audit))
                target = args.fixture if operation == "read" else directory
                run = subprocess.run([str(binary), operation, str(target)], env=env,
                                     text=True, capture_output=True, timeout=20)
                assert run.returncode == 0, (operation, mode, run.stdout, run.stderr)
                assert audit.exists(), (operation, mode, "fake library was not loaded")
                initialized, ended, active = map(int, audit.read_text().split())
                expected = 0 if mode in {"abi", "winapi", "no-gzip", "init-memory"} else 1
                assert (initialized, ended, active) == (expected, expected, 0), (
                    operation, mode, initialized, ended, active)
                results.append({"operation": operation, "mode": mode,
                                "initialized": initialized, "ended": ended, "active": active})
        # An invalid ELF at the requested SONAME forces a dependency-load error
        # even on hosts where a normal libz is installed. No fallback is allowed.
        with tempfile.TemporaryDirectory(dir=BUILD) as directory:
            dependency = Path(directory) / "dependency"
            dependency.mkdir()
            (dependency / "libz.so.1").write_bytes(b"unloadable dependency")
            target = Path(directory) / "output"
            target.mkdir()
            env = dict(os.environ, LD_LIBRARY_PATH=str(dependency))
            run = subprocess.run([str(binary), operation,
                                  str(args.fixture if operation == "read" else target)],
                                 env=env, text=True, capture_output=True, timeout=20)
            assert run.returncode == 0, (operation, "unloadable", run.stdout, run.stderr)
            assert "expected codec failure" in run.stdout
            results.append({"operation": operation, "mode": "unloadable", "passed": True})
    report = json.dumps(results, indent=2) + "\n"
    (BUILD / "results.json").write_text(report)
    print(f"Passed {len(results)} injected codec failure cases")


if __name__ == "__main__":
    main()
