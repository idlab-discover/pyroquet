"""Cross-check native footer inspection and reject malformed file/metadata cases."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

import fastparquet
from thrift.Thrift import TType
from thrift.protocol.TCompactProtocol import TCompactProtocol
from thrift.transport.TTransport import TMemoryBuffer

from check_compact_interop import write_struct

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/footer-checks"


def envelope(fields):
    buffer = TMemoryBuffer()
    write_struct(TCompactProtocol(buffer), fields)
    footer = buffer.getvalue()
    return b"PAR1" + footer + struct.pack("<I", len(footer)) + b"PAR1"


def empty_fields():
    return [
        (1, TType.I32, 1),
        (2, TType.LIST, (TType.STRUCT, [[(4, TType.STRING, b"schema"), (5, TType.I32, 0)]])),
        (3, TType.I64, 0),
        (4, TType.LIST, (TType.STRUCT, [])),
    ]


def malformed_cases():
    valid = envelope(empty_fields())
    yield "short", b"PAR1"
    yield "bad_head", b"FAIL" + valid[4:]
    yield "bad_tail", valid[:-4] + b"FAIL"
    yield "outside_file", valid[:-8] + b"\xff" * 4 + b"PAR1"
    yield "zero_footer", b"PAR1" + b"\0" * 4 + b"PAR1"
    for index in range(4):
        fields = empty_fields()
        del fields[index]
        yield f"missing_{index}", envelope(fields)
    fields = empty_fields()
    yield "duplicate_version", envelope(fields + [fields[0]])
    fields[0] = (1, TType.BOOL, True)
    yield "wrong_type", envelope(fields)
    fields = empty_fields()
    fields[0] = (1, TType.I32, 99)
    yield "bad_version", envelope(fields)
    fields = empty_fields()
    fields[1] = (2, TType.LIST, (TType.STRUCT, []))
    yield "missing_schema_root", envelope(fields)
    fields = empty_fields()
    fields[2] = (3, TType.I64, -1)
    yield "negative_rows", envelope(fields)
    fields[2] = (3, TType.I64, 1)
    yield "rows_disagree", envelope(fields)
    fields = empty_fields()
    fields[3] = (4, TType.LIST, (TType.STRUCT, [[]]))
    yield "missing_rowgroup_fields", envelope(fields)
    group = [(1, TType.LIST, (TType.STRUCT, [])), (2, TType.I64, 0), (3, TType.I64, 2**63 - 1)]
    fields[3] = (4, TType.LIST, (TType.STRUCT, [group, group]))
    yield "row_sum_overflow", envelope(fields)
    for length in range(1, len(valid) - 12):
        body = valid[4:4 + length]
        yield f"truncated_footer_{length}", b"PAR1" + body + struct.pack("<I", length) + b"PAR1"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    binary = OUT / "inspect"
    subprocess.run(["pixi", "run", "mojo", "build", "-O3", "-I", "src",
                    "tests/inspect_footer.mojo", "-o", str(binary)], cwd=ROOT, check=True)
    paths = sorted((ROOT / "build/fixtures/uint32").glob("*.parquet"))
    if len(paths) < 9:
        raise RuntimeError("Run tests/make_uint32_fixtures.py first")
    corpus = ROOT.parent / "fastparquet"
    names = subprocess.check_output(["git", "-C", str(corpus), "ls-files", "-z", "test-data"]).split(b"\0")
    for name in names:
        if not name:
            continue
        path = corpus / name.decode()
        with path.open("rb") as file:
            if file.read(4) == b"PAR1":
                paths.append(path)
    # The local specification accepts both metadata versions 1 and 2.
    for version in (1, 2):
        fields = empty_fields()
        fields[0] = (1, TType.I32, version)
        path = OUT / f"empty_version_{version}.parquet"
        path.write_bytes(envelope(fields))
        paths.append(path)
    checked = []
    inconsistent = []
    for path in paths:
        oracle = fastparquet.ParquetFile(path)
        result = subprocess.run([str(binary), str(path)], capture_output=True, text=True)
        if oracle.fmd.num_rows != sum(group.num_rows for group in oracle.row_groups):
            # Known incorrectly encoded corpus fixture:
            # repeated_no_annotation.parquet declares 0 footer rows but 6
            # row-group rows. Rejection is expected; this is not a valid-file
            # compatibility failure. Keep the original fixture without repair.
            assert result.returncode == 1 and "Footer and row-group row counts disagree" in result.stdout + result.stderr, (path, result)
            inconsistent.append({"path": str(path), "footer_rows": oracle.fmd.num_rows,
                                 "group_rows": [group.num_rows for group in oracle.row_groups]})
            continue
        if result.returncode:
            raise RuntimeError(f"{path}: {result.stdout}{result.stderr}")
        lines = result.stdout.splitlines()
        assert list(map(int, lines[0].split())) == [oracle.fmd.version, oracle.fmd.num_rows, len(oracle.fmd.schema)], path
        assert list(map(int, lines[1:])) == [group.num_rows for group in oracle.row_groups], path
        checked.append({"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    rejected = []
    for name, data in malformed_cases():
        path = OUT / (name + ".parquet")
        path.write_bytes(data)
        result = subprocess.run([str(binary), str(path)], capture_output=True, text=True)
        assert result.returncode == 1 and "Unhandled exception caught" in result.stdout + result.stderr, (name, result)
        rejected.append(name)
    (OUT / "manifest.json").write_text(json.dumps({
        "scope": "Footer envelope and selected metadata only; no data decoding claim",
        "oracle": fastparquet.__version__, "checked": checked, "rejected": rejected,
        "inconsistent_corpus_metadata": inconsistent,
    }, indent=2) + "\n")
    print(f"Verified {len(checked)} native footer summaries; rejected {len(rejected)} malformed files and {len(inconsistent)} corpus files with inconsistent row counts")


if __name__ == "__main__":
    main()
