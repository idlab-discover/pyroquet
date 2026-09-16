"""Verify committed Snappy source/package resolution with the pinned compiler.

Run with Python; artifacts stay in build/snappy-resolution. This never rebuilds
the live Pixi dependency or edits its checkout. Installed revision identity is
unknown unless its package bytes equal the freshly precompiled commit.
"""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = """from mojo_snappy import decode_snappy
def main() raises:
    var decoded = decode_snappy([4, 12, 1, 2, 3, 4], 4)
    if len(decoded) != 4:
        raise Error("Resolution probe output length")
    print(Int(decoded[0]), Int(decoded[1]), Int(decoded[2]), Int(decoded[3]))
"""
MARKER = """def decode_snappy(
    data: List[UInt8], expected_size: Int, start: Int = 0
) raises -> List[UInt8]:
    return [UInt8(91), 92, 93, 94]
"""


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="a4c9440")
    parser.add_argument("--codec-repo", type=Path, default=ROOT.parent / "mojo-snappy")
    args = parser.parse_args()
    repo = args.codec_repo.resolve()
    prefix = ROOT / ".pixi/envs/default"
    compiler = prefix / "bin/mojo"
    original_home = prefix / "share/max"
    original_config = original_home / "modular.cfg"
    destination = ROOT / "build/snappy-resolution"
    destination.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="check-", dir=destination))
    print("Evidence:", out, flush=True)
    git = lambda *a: subprocess.check_output(["git", "-C", str(repo), *a])
    commit = git("rev-parse", "--verify", "--end-of-options", args.revision + "^{commit}").decode().strip()
    source = out / "source"
    paths = git("ls-tree", "-r", "--name-only", commit, "src/mojo_snappy").decode().splitlines()
    if not paths:
        raise RuntimeError("Selected commit has no src/mojo_snappy package")
    for name in paths:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(git("show", commit + ":" + name))
    home = out / "modular"
    stdlib = out / "stdlib"
    home.mkdir()
    stdlib.mkdir()
    std = prefix / "lib/mojo/std.mojoc"
    (stdlib / std.name).symlink_to(std)
    config = configparser.ConfigParser(interpolation=None)
    config.read(original_config)
    config["mojo-max"]["import_path"] = str(stdlib)
    with (home / "modular.cfg").open("w") as file:
        config.write(file)
    marker = out / "marker"
    (marker / "mojo_snappy").mkdir(parents=True)
    (marker / "mojo_snappy/__init__.mojo").write_text(MARKER)
    shadow = out / "shadow"
    (shadow / "mojo_snappy").mkdir(parents=True)
    shadow_file = shadow / "mojo_snappy/__init__.mojo"
    shadow_file.write_text("this is intentionally invalid shadow source\n")
    probe = out / "probe.mojo"
    probe.write_text(PROBE)
    installed = prefix / "lib/mojo/mojo_snappy.mojoc"
    manifest = {
        "commit": commit, "codec_repo": str(repo), "compiler": str(compiler),
        "compiler_sha256": sha(compiler),
        "excluded_worktree_status": git("status", "--short").decode(),
        "source_sha256": {name: sha(source / name) for name in paths},
        "controls_sha256": {str(p): sha(p) for p in
                            (probe, shadow_file, marker / "mojo_snappy/__init__.mojo")},
        "stdlib": {"path": str(std), "sha256": sha(std)},
        "installed_sha256": sha(installed) if installed.exists() else None,
        "installed_revision_identity": "unknown", "steps": [],
    }

    def save():
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def run(name, argv, *, modular_home=home, expected=None, negative=False):
        env = os.environ.copy()
        env["MODULAR_HOME"] = str(modular_home)
        result = subprocess.run(list(map(str, argv)), env=env, cwd=ROOT, text=True,
                                capture_output=True)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        manifest["steps"].append({
            "name": name, "argv": list(map(str, argv)), "exit": result.returncode,
            "MODULAR_HOME": str(modular_home),
            "config_sha256": sha(modular_home / "modular.cfg"),
            "stdout": result.stdout,
        })
        save()
        if negative:
            if result.returncode == 0 or str(shadow_file) not in result.stderr or "error:" not in result.stderr:
                raise RuntimeError("Shadow source was not rejected: " + name)
        elif result.returncode or (expected is not None and result.stdout.strip() != expected):
            raise RuntimeError("Unexpected resolution result: " + name + "; see " + str(out))

    run("compiler", [compiler, "--version"])
    package = out / "package"
    package.mkdir()
    packed = package / "mojo_snappy.mojoc"
    run("precompile", [compiler, "precompile", source / "src/mojo_snappy", "-o", packed])
    manifest["package_sha256"] = sha(packed)
    if manifest["package_sha256"] == manifest["installed_sha256"]:
        manifest["installed_revision_identity"] = "exact package match to selected commit"
    for mode in ("default", "all", "none"):
        flags = [compiler, "build", "-O3"]
        if mode != "default":
            flags += ["-D", "ASSERT=" + mode]
        for route, includes, expected in (
            ("source", [source / "src", marker, shadow], "1 2 3 4"),
            ("marker", [marker, shadow], "91 92 93 94"),
            ("package", [package, marker, shadow], "1 2 3 4"),
        ):
            name = route + "-" + mode
            binary = out / name
            argv = flags.copy()
            for include in includes:
                argv += ["-I", include]
            run(name + "-build", argv + [probe, "-o", binary])
            manifest["steps"][-1]["binary_sha256"] = sha(binary)
            run(name, [binary], expected=expected)
        run("shadow-" + mode, flags + ["-I", shadow, probe, "-o", out / ("bad-" + mode)], negative=True)
        if installed.exists():
            binary = out / ("installed-" + mode)
            run("installed-" + mode + "-build", flags + ["-I", marker, "-I", shadow, probe, "-o", binary], modular_home=original_home)
            manifest["steps"][-1]["binary_sha256"] = sha(binary)
            run("installed-" + mode, [binary], expected="1 2 3 4", modular_home=original_home)
    manifest["result"] = "passed source/package resolution controls"
    save()
    print(manifest["result"])
    print("Installed revision identity:", manifest["installed_revision_identity"])


if __name__ == "__main__":
    main()
