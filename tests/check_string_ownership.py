"""Compile-time gates for consumed builders and immutable string storage."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = """from pyroquet.binary_column import BinaryColumn
from pyroquet.string_column import StringColumn, StringBuilder
"""
CASES = {
    "valid_owned_value": (True, """
def materialize() raises -> String:
    var builder = StringBuilder()
    builder.append("hello")
    var column = builder^.freeze()
    return column.value(0)

def main() raises:
    print(materialize())
"""),
    "valid_borrow": (True, """
def main() raises:
    var column = StringColumn(BinaryColumn([0, 1], [65]))
    var bytes = column.binary().value(0)
    print(bytes[0])
"""),
    "mutate_borrow": (False, """
def main() raises:
    var column = StringColumn(BinaryColumn([0, 1], [65]))
    var bytes = column.binary().value(0)
    bytes[0] = 255
"""),
    "reuse_builder": (False, """
def main() raises:
    var builder = StringBuilder()
    var column = builder^.freeze()
    builder.append_null()
    print(len(column))
"""),
    "escape_borrow": (False, """
def escape() raises -> Span[UInt8, ImmStaticOrigin]:
    var column = StringColumn(BinaryColumn([0, 1], [65]))
    return column.binary().value(0)

def main() raises:
    print(escape()[0])
"""),
    "replace_borrowed_binary": (False, """
def main() raises:
    var column = StringColumn(BinaryColumn([0, 1], [65]))
    column.binary() = BinaryColumn([0, 1], [255])
    print(column.value(0))
"""),
}


def main():
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="string-ownership-", dir=build) as directory:
        for name, (should_compile, source) in CASES.items():
            path = Path(directory) / (name + ".mojo")
            path.write_text(PRELUDE + source)
            result = subprocess.run(
                ["pixi", "run", "mojo", "build", "-I", "src", "-I", "../NuMojo",
                 str(path), "-o", str(Path(directory) / name)],
                cwd=ROOT, capture_output=True, text=True,
            )
            if (result.returncode == 0) != should_compile:
                raise RuntimeError(name + "\n" + result.stdout + result.stderr)
            if not should_compile and "error:" not in result.stderr:
                raise RuntimeError("Compiler did not report a source error: " + result.stderr)
            print("PASS", name)


if __name__ == "__main__":
    main()
