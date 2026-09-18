"""Compile-time nested ENUM borrowing and ownership gates."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = '''from pyroquet.nested_table import NestedTable, NestedStructure
from pyroquet.enum_column import EnumBuilder, EnumColumn
from pyroquet import Schema, SchemaNode, Column

def table() raises -> NestedTable:
    var builder = EnumBuilder(1)
    var bytes: List[UInt8] = [65]
    builder.append_bytes(Span(bytes))
    return NestedTable(Schema([SchemaNode("root", SchemaNode.GROUP, -1),
                        SchemaNode("s", SchemaNode.GROUP, 0),
                        SchemaNode("e", SchemaNode.ENUM, 1)]),
                       [Column("e", builder^.freeze())], [NestedStructure(1)], 1)
'''
CASES = {
    "valid_borrow": (True, '''def main() raises:
    var t = table()
    ref e = t.leaf(0).enumeration()
    print(e.value(0))
    print(e.labels().binary().value(0)[0])
    print(e.indices().value(0).value())
    print(t.leaf(0)._byte_value(0)[0])
'''),
    "mutate_labels": (False, '''def main() raises:
    var t = table()
    t.leaf(0).enumeration().labels().binary().value(0)[0] = 255
'''),
    "mutate_indices": (False, '''def main() raises:
    var t = table()
    t.leaf(0).enumeration().indices().values().unsafe_ptr()[unsafe_offset=0] = 9
'''),
    "escape_enum": (False, '''def escape() raises -> ref[ImmStaticOrigin] EnumColumn:
    var t = table()
    return t.leaf(0).enumeration()
def main() raises:
    print(escape().value(0))
'''),
    "move_enum": (False, '''def main() raises:
    var t = table()
    var e = t.leaf(0).enumeration()^
    print(e.value(0))
'''),
    "escape_bytes": (False, '''def escape() raises -> Span[UInt8, ImmStaticOrigin]:
    var t = table()
    return t.leaf(0)._byte_value(0)
def main() raises:
    print(escape()[0])
'''),
    "mutate_bytes": (False, '''def main() raises:
    var t = table()
    t.leaf(0)._byte_value(0)[0] = 255
'''),
}


def main():
    out = ROOT / "build/enum-nested-ownership"
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
