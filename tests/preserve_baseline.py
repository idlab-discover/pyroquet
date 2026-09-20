"""Snapshot the sibling baseline without changing its worktree or old evidence.

Retain nonignored tracked/untracked files and a Git diff, including dirty source.
Ignored build products are not source inputs; retain selected probe/fixture
identities separately. Each invocation creates a fresh directory under build/.
"""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT.parent / "pyroquet-legacy"


def git(*args):
    return subprocess.check_output(["git", "-C", str(BASELINE), *args])


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    destination = ROOT / "build/baseline" / stamp
    destination.mkdir(parents=True)
    names = sorted(set(git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")) - {b""})
    manifest = {
        "head": git("rev-parse", "HEAD").decode().strip(),
        "status": git("status", "--short").decode(),
        "source_root": str(BASELINE),
        "files": {},
        "deleted": [],
        "probe_artifacts": {},
    }
    with tarfile.open(destination / "source.tar.gz", "w:gz") as archive:
        for raw in names:
            name = raw.decode()
            path = BASELINE / name
            if not path.exists():
                manifest["deleted"].append(name)
                continue
            if not path.is_file() or path.is_symlink():
                raise ValueError("Unsupported snapshot input: " + name)
            manifest["files"][name] = digest(path)
            archive.add(path, arcname=name, recursive=False)
    (destination / "working-tree.patch").write_bytes(git("diff", "--binary", "HEAD"))
    for name in (
        "build/rewrite-exploration/decode_phases",
        "test-data/customer.impala.parquet",
    ):
        path = BASELINE / name
        manifest["probe_artifacts"][name] = digest(path) if path.is_file() else None
    manifest["archive_sha256"] = digest(destination / "source.tar.gz")
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # Verify archived bytes against their recorded digests before reporting success.
    with tarfile.open(destination / "source.tar.gz") as archive:
        for name, expected in manifest["files"].items():
            with archive.extractfile(name) as member:
                if hashlib.sha256(member.read()).hexdigest() != expected:
                    raise ValueError("Source changed during snapshot: " + name)
    print("Preserved", len(manifest["files"]), "baseline files:", destination)


if __name__ == "__main__":
    main()
