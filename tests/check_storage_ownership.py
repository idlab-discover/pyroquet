"""Compile-time gates for freeze, immutable borrows, and borrow escape."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = "from pyroquet.storage import BufferBuilder, FrozenBuffer\n"
CASES = {
    "valid": (True, """
def main() raises:
    var builder = BufferBuilder[UInt32]()
    builder.append(7)
    var frozen = builder^.freeze()
    print(frozen.view()[0])
"""),
    "mutate_frozen": (False, """
def main() raises:
    var frozen = FrozenBuffer[UInt32]([7])
    var view = frozen.view()
    view[0] = 8
"""),
    "reuse_builder": (False, """
def main() raises:
    var builder = BufferBuilder[UInt32]()
    var frozen = builder^.freeze()
    builder.append(8)
    print(len(frozen))
"""),
    "escape_borrow": (False, """
def escape() -> Span[UInt32, ImmStaticOrigin]:
    var frozen = FrozenBuffer[UInt32]([7])
    return frozen.view()

def main():
    print(escape()[0])
"""),
}


def main():
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ownership-", dir=build) as directory:
        for name, (should_compile, source) in CASES.items():
            path = Path(directory) / (name + ".mojo")
            path.write_text(PRELUDE + source)
            result = subprocess.run(
                ["pixi", "run", "mojo", "build", "-I", "src", str(path),
                 "-o", str(Path(directory) / name)],
                cwd=ROOT, capture_output=True, text=True,
            )
            if (result.returncode == 0) != should_compile:
                raise RuntimeError(name + "\n" + result.stdout + result.stderr)
            if not should_compile and "error:" not in result.stderr:
                raise RuntimeError("Compiler did not report a source error: " + result.stderr)
            print("PASS", name)


if __name__ == "__main__":
    main()
