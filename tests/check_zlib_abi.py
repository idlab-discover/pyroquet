"""Compile the installed-header ABI audit and record the resolved zlib identity.

Run with build/oracle-uv/bin/python tests/check_zlib_abi.py. Requires a C compiler
and zlib development headers. This is a development tool, never library execution.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "gzip-abi"
PREFIX = Path(os.environ.get("CONDA_PREFIX", ROOT / ".pixi/envs/default"))


def main() -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    command = [os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror",
               str(ROOT / "tests/zlib_abi.c"), "-ldl", f"-Wl,-rpath,{PREFIX / 'lib'}",
               "-o", str(BUILD / "zlib-abi")]
    # Prefer headers from the pinned environment when installed; otherwise the
    # system's installed zlib headers are checked against the resolved library.
    if (PREFIX / "include/zlib.h").exists():
        command[1:1] = [f"-I{PREFIX / 'include'}"]
    subprocess.run(command, check=True)
    output = subprocess.check_output([str(BUILD / "zlib-abi")], text=True)
    result = dict(line.split("=", 1) for line in output.splitlines())
    library = Path(result["library"]).resolve()
    result["resolved_library"] = str(library)
    result["sha256"] = hashlib.sha256(library.read_bytes()).hexdigest()
    result["compile_command"] = command
    report = json.dumps(result, indent=2) + "\n"
    (BUILD / "identity.json").write_text(report)
    print(report, end="")


if __name__ == "__main__":
    main()
