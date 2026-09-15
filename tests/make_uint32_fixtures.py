"""Generate the first rewrite corpus; Python packages are test oracles only.

Run with the dependencies in tests/oracle-requirements.txt. Artifacts go to
build/fixtures/uint32; manifest.json records values, schema, groups and hashes.
"""

import hashlib
import json
from pathlib import Path
import struct

import duckdb
import fastparquet
from fastparquet.cencoding import ThriftObject
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "extrema": [0, 2**31 - 1, None, 2**31, 2**32 - 1, 1, None],
    "all_null": [None] * 7,
    "empty": [],
}


def verify(connection, path, values, expected_groups, producer, page_version):
    file = fastparquet.ParquetFile(path)
    field = file.schema.schema_elements[1]
    # INT32 + UINT_32 + OPTIONAL. Inspect wire annotations, not pandas
    # metadata, because adapters must not decide native logical identity.
    assert (field.type, field.converted_type, field.repetition_type) == (1, 13, 1)
    actual = file.to_pandas()["value"]
    assert str(actual.dtype) in ("UInt32", "uint32"), (path.name, str(actual.dtype))
    assert [None if pd.isna(x) else int(x) for x in actual] == values
    relation = connection.read_parquet(str(path))
    assert [str(t) for t in relation.types] == ["UINTEGER"]
    assert [row[0] for row in relation.fetchall()] == values
    groups = [group.num_rows for group in file.row_groups]
    assert groups == expected_groups
    for group in file.row_groups:
        metadata = group.columns[0].meta_data
        assert metadata.codec == 0
        if group.num_rows == 0:
            continue
        header = ThriftObject.from_buffer(
            path.read_bytes()[metadata.data_page_offset:], "PageHeader"
        )
        assert header.type == (0 if page_version == 1 else 3)
        data_header = header.data_page_header if page_version == 1 else header.data_page_header_v2
        assert data_header.encoding == 0  # PLAIN
    arrow = pq.read_table(path)
    assert arrow.schema.field("value").type == pa.uint32()
    assert arrow.column("value").to_pylist() == values
    return {
        "producer": producer,
        "modern_integer_annotation": field.logicalType is not None,
        "file": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "values": values,
        "logical_type": "UInt32",
        "nullable": True,
        "row_group_rows": groups,
        "page_version": page_version if values else None,
        "encoding": "PLAIN",
        "codec": "UNCOMPRESSED",
        "physical_non_null_le_hex": b"".join(
            struct.pack("<I", value) for value in values if value is not None
        ).hex(),
        "verified_readers": ["fastparquet", "duckdb", "pyarrow"],
    }


def main():
    destination = ROOT / "build/fixtures/uint32"
    destination.mkdir(parents=True, exist_ok=True)
    report = {
        "purpose": "Independent input fixtures; no Pyroquet read/write claim",
        "versions": {
            "fastparquet": fastparquet.__version__,
            "duckdb": duckdb.__version__,
            "pandas": pd.__version__,
            "pyarrow": pa.__version__,
        },
        "cases": {},
    }
    with duckdb.connect() as connection:
        connection.execute("SET threads=1")
        connection.execute("SET preserve_insertion_order=true")
        for name, values in CASES.items():
            path = destination / (name + ".parquet")
            frame = pd.DataFrame({"value": pd.Series(values, dtype="UInt32")})
            fastparquet.write(
                str(path), frame, compression=None, write_index=False,
                has_nulls=True, row_group_offsets=3,
            )
            report["cases"][name] = verify(
                connection, path, values, [3, 3, 1] if values else [], "fastparquet", 1
            )
            for page_version in (1, 2):
                arrow_name = f"arrow_v{page_version}_{name}"
                arrow_path = destination / (arrow_name + ".parquet")
                table = pa.table({"value": pa.array(values, type=pa.uint32())})
                pq.write_table(
                    table, arrow_path, compression="NONE", use_dictionary=False,
                    row_group_size=3, data_page_version=f"{page_version}.0",
                )
                report["cases"][arrow_name] = verify(
                    connection, arrow_path, values, [3, 3, 1] if values else [0],
                    "pyarrow", page_version,
                )
    (destination / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Verified", len(report["cases"]), "UInt32 fixtures:", destination)


if __name__ == "__main__":
    main()
