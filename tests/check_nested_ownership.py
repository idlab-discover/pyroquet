"""Compile gates for heterogeneous table ownership and immutable typed borrows."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = '''from pyroquet.nested_table import NestedTable, NestedStructure
from pyroquet.numeric_column import NumericColumn
from pyroquet import Schema, SchemaNode, Column
from numojo.routines.creation import empty

def table() raises -> NestedTable:
    var values = empty[DType.uint64]([1])
    values.unsafe_ptr()[unsafe_offset=0] = UInt64.MAX
    var column = Column(NumericColumn(values^, List[UInt8](), "x", 0))
    return NestedTable(Schema([SchemaNode("root", SchemaNode.GROUP, -1),
                        SchemaNode("s", SchemaNode.GROUP, 0),
                        SchemaNode("x", SchemaNode.UINT64, 1)]), [column^], [NestedStructure(1)], 1)
'''
CASES = {
    "valid": (True, '''def main() raises:
    var t = table()
    print(t.leaf(0).numeric[DType.uint64]().value(0).value())
'''),
    "mutate_values": (False, '''def main() raises:
    var t = table()
    t.leaf(0).numeric[DType.uint64]().values().unsafe_ptr()[unsafe_offset=0] = 7
'''),
    "mutate_validity": (False, '''def main() raises:
    var t = table()
    var bitmap = t.leaf(0).numeric[DType.uint64]().validity()
    bitmap[0] = 0
'''),
    "escape_values": (False, '''def escape() raises -> Pointer[UInt64, ImmStaticOrigin]:
    var t = table()
    return t.leaf(0).numeric[DType.uint64]().values().unsafe_ptr()
def main() raises:
    print(escape()[unsafe_offset=0])
'''),
    "escape_column": (False, '''def escape() raises -> ref[ImmStaticOrigin] NumericColumn[DType.uint64]:
    var t = table()
    return t.leaf(0).numeric[DType.uint64]()
def main() raises:
    print(escape().size())
'''),
    "move_borrowed_column": (False, '''def main() raises:
    var t = table()
    var c = t.leaf(0).numeric[DType.uint64]()^
    print(c.size())
'''),
    "copy_table": (False, '''def main() raises:
    var t = table()
    var other = t.copy()
    print(other.num_rows())
'''),
    "copy_column": (False, '''def main() raises:
    var t = table()
    var other = t.leaf(0).copy()
    print(other.size())
'''),
}


def main():
    out = ROOT / "build/nested-ownership"
    out.mkdir(parents=True, exist_ok=True)
    for name, (valid, source) in CASES.items():
        path = out / (name + ".mojo")
        path.write_text(PRELUDE + "\n" + source)
        result = subprocess.run(
            ["pixi", "run", "mojo", "build", "-I", "src", "-I", "../NuMojo",
             str(path), "-o", str(out / name)],
            cwd=ROOT, text=True, capture_output=True,
        )
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        assert (result.returncode == 0) == valid, (name, result.stderr)
        if not valid:
            assert "error:" in result.stderr
        print("PASS", name, flush=True)


if __name__ == "__main__":
    main()
