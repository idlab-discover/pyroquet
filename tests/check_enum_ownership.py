"""Compile gates for bounded enum index reads and immutable label borrows."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = """from pyroquet.enum_column import EnumColumn, EnumBuilder
from pyroquet.string_column import StringColumn
from pyroquet.numeric_column import NumericColumn

def column() raises -> EnumColumn:
    var builder = EnumBuilder(1)
    builder.append("label")
    return builder^.freeze()
"""
CASES = {
    "valid_borrows": (True, """
def main() raises:
    var c = column()
    print(c.labels().value(0))
    print(c.indices().value(0).value())
"""),
    "owned_value_escapes": (True, """
def materialize() raises -> String:
    var c = column()
    return c.value(0)

def main() raises:
    print(materialize())
"""),
    "copy_enum": (False, """
def main() raises:
    var c = column()
    var other = c.copy()
    print(other.value(0))
"""),
    "reuse_moved_enum": (False, """
def main() raises:
    var c = column()
    var moved = c^
    print(c.value(0))
    print(moved.value(0))
"""),
    "reuse_builder": (False, """
def main() raises:
    var b = EnumBuilder(1)
    b.append("label")
    var c = b^.freeze()
    b.append_null()
    print(c.value(0))
"""),
    "mutate_label_bytes": (False, """
def main() raises:
    var c = column()
    c.labels().binary().value(0)[0] = 255
"""),
    "mutate_indices": (False, """
def main() raises:
    var c = column()
    c.indices().values().unsafe_ptr()[unsafe_offset=0] = 99
"""),
    "mutate_validity": (False, """
def main() raises:
    var c = column()
    c.indices().validity()[0] = 0
"""),
    "move_index_view": (True, """
def main() raises:
    var c = column()
    var moved = c.indices()^
    print(moved.size())
"""),
    "escape_labels": (False, """
def escape() raises -> ref[ImmStaticOrigin] StringColumn:
    var c = column()
    return c.labels()

def main() raises:
    print(escape().value(0))
"""),
    "escape_indices": (False, """
def escape() raises -> ref[ImmStaticOrigin] NumericColumn[DType.uint32]:
    var c = column()
    return c.indices()

def main() raises:
    print(escape().size())
"""),
    "escape_label_bytes": (False, """
def escape() raises -> Span[UInt8, ImmStaticOrigin]:
    var c = column()
    return c.labels().binary().value(0)

def main() raises:
    print(escape()[0])
"""),
}


def main():
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    # Preserve compiler sources and diagnostics for failures and avoid a cleanup
    # context masking exceptions in environments with patched tempfile behavior.
    directory = Path(tempfile.mkdtemp(prefix="enum-ownership-", dir=build))
    for name, (should_compile, source) in CASES.items():
        path = directory / (name + ".mojo")
        path.write_text(PRELUDE + source)
        result = subprocess.run(
            ["pixi", "run", "mojo", "build", "-I", "src", "-I", "../NuMojo",
             str(path), "-o", str(directory / name)],
            cwd=ROOT, capture_output=True, text=True,
        )
        (directory / (name + ".log")).write_text(result.stdout + result.stderr)
        if (result.returncode == 0) != should_compile:
            raise RuntimeError(name + "\n" + result.stdout + result.stderr)
        if not should_compile and "error:" not in result.stderr:
            raise RuntimeError("Compiler did not report a source error: " + result.stderr)
        print("PASS", name)


if __name__ == "__main__":
    main()
