"""Compile-time gates for freeze, immutable borrows, and borrow escape."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = "from pyroquet.binary_column import BinaryColumn, BinaryBuilder\n"
CASES = {
    "table_escape": (False, """
from pyroquet import Schema, SchemaNode, Column, Table

def escape() raises -> Span[UInt8, ImmStaticOrigin]:
    var t = Table(Schema([SchemaNode("root", SchemaNode.GROUP, -1), SchemaNode("raw", SchemaNode.BINARY, 0)]), [Column("raw", BinaryColumn([0, 1], [255]))], 1)
    return t.column(0).binary().value(0)

def main() raises:
    print(escape()[0])
"""),
    "valid": (True, """
def main() raises:
    var builder = BinaryBuilder()
    var data: List[UInt8] = [255]
    builder.append(Span(data))
    var column = builder^.freeze()
    print(column.value(0)[0])
"""),
    "mutate_borrow": (False, """
def main() raises:
    var column = BinaryColumn([0, 1], [255])
    var bytes = column.value(0)
    bytes[0] = 0
"""),
    "reuse_builder": (False, """
def main() raises:
    var builder = BinaryBuilder()
    var column = builder^.freeze()
    builder.append_null()
    print(len(column))
"""),
    "escape_borrow": (False, """
def escape() raises -> Span[UInt8, ImmStaticOrigin]:
    var column = BinaryColumn([0, 1], [255])
    return column.value(0)

def main() raises:
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
                ["pixi", "run", "mojo", "build", "-I", "src", "-I", "../NuMojo", str(path),
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
