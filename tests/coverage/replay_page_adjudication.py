"""Replay two legacy golden failures and verify surgical diagnostic copies.

Uses the development oracle environment. Writes only to the output directory;
source hashes are pinned because the byte edits are fixture-specific.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from page_evidence import inspect_page_evidence

ROOT = Path(__file__).resolve().parents[2]
SOURCES = {
    "customer.impala.parquet": "7eea206081adb55bcc12bac4e0903d7c8d4b1b086636d67b19b9cd068a7dae5b",
    "non-std-kvm.fp-0.8.2.parquet": "9ad6fa450a3f4d29abcb500b9440d9835a397ec374dd72a72423e1342c8dc81c",
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def corrected_bytes(source, raw, evidence):
    """Construct a diagnostic copy, requiring the exact inspected source bytes."""
    if sha256(raw) != SOURCES[source.name]:
        raise ValueError("fixture-specific correction requires the pinned source hash")
    from fastparquet import ParquetFile
    from fastparquet.cencoding import NumpyIO, ThriftObject

    first = evidence["findings"][0]
    if source.name == "customer.impala.parquet":
        corrected = bytearray(raw)
        for finding in evidence["findings"]:
            value = finding["header_num_values"] << 1
            encoded = bytearray()
            while value >= 128:
                encoded.append((value & 127) | 128)
                value >>= 7
            encoded.append(value)
            start = finding["payload_offset"] + 4
            assert len(encoded) == len(bytes.fromhex(finding["definition_level_bytes_hex"])) - 1
            corrected[start:start + len(encoded)] = encoded
        return bytes(corrected)

    header = ThriftObject.from_buffer(NumpyIO(raw[4:]), "PageHeader")
    header.compressed_page_size -= 8
    header.uncompressed_page_size -= 8
    pf = ParquetFile(source)
    group = pf.row_groups[0]
    column = group.columns[0]
    column.file_offset -= 8
    column.meta_data.total_compressed_size -= 8
    column.meta_data.total_uncompressed_size -= 8
    group.total_byte_size -= 8
    footer = bytes(pf.fmd.to_bytes())
    return (b"PAR1" + bytes(header.to_bytes())
            + raw[first["payload_offset"]:first["page_end"] - 8]
            + footer + struct.pack("<I", len(footer)) + b"PAR1")


def replay(source_dir, loader, output):
    import numpy as np
    import fastparquet
    import pyarrow
    import pyarrow.parquet as pq
    import duckdb

    source_dir, loader, output = (p.resolve() for p in (source_dir, loader, output))
    if source_dir == output or source_dir in output.parents:
        raise ValueError("output must be outside the source corpus directory")
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for name, expected_hash in SOURCES.items():
        source = source_dir / name
        raw = source.read_bytes()
        if sha256(raw) != expected_hash:
            raise ValueError(f"unexpected fixture hash: {source}")
        evidence = inspect_page_evidence(source)
        (output / (name + ".evidence.json")).write_text(json.dumps(evidence, indent=2))
        first = evidence["findings"][0]
        extract = raw[first["page_offset"]:first["page_end"]]
        (output / (name + ".first-page.bin")).write_bytes(extract)
        names = ["a"] if name.startswith("non-") else ["c_custkey", "c_nationkey", "c_acctbal"]
        arrow = pq.read_table(source, columns=names)
        frame = fastparquet.ParquetFile(source).to_pandas(columns=names)
        with duckdb.connect() as connection:
            duck = connection.execute(
                "SELECT " + ",".join(names) + " FROM read_parquet(?)", [str(source)]
            ).to_arrow_table()
        for col in names:
            a = arrow[col].to_numpy()
            d = duck[col].to_numpy()
            assert str(frame[col].dtype).lower() == str(a.dtype)
            assert arrow[col].type == duck[col].type
            f = frame[col].to_numpy(dtype=a.dtype)
            assert a.tobytes() == d.tobytes() == f.tobytes()
            assert arrow[col].null_count == duck[col].null_count == int(frame[col].isna().sum()) == 0
        corrected = corrected_bytes(source, raw, evidence)
        target = output / (name + ".corrected.parquet")
        target.write_bytes(corrected)
        commands = []
        for path, label in [(source, "original"), (target, "corrected")]:
            dump = output / (name + "." + label + ".dump")
            command = [str(loader), str(path), str(dump), "1", *names]
            process = subprocess.run(command, capture_output=True, text=True)
            commands.append(dict(label=label, command=command, returncode=process.returncode,
                                 stdout=process.stdout, stderr=process.stderr))
            assert process.returncode == (1 if label == "original" else 0), commands[-1]
            if label == "original":
                expected = ("Definition-level RLE run exceeds page" if name.startswith("customer")
                            else "PLAIN byte length disagrees with non-null value count")
                assert expected in process.stdout + process.stderr
        assert pq.read_table(target, columns=names).equals(arrow)
        reference = bytearray()
        for col in names:
            a = arrow[col].to_numpy()
            bits = a.view("uint64") if a.dtype.kind == "f" else a.astype("uint64")
            values = np.empty(len(a), dtype=np.dtype([("valid", "u1"), ("bits", "<u8")]))
            values["valid"] = 1
            values["bits"] = bits
            reference.extend(values.tobytes())
        assert (output / (name + ".corrected.dump")).read_bytes() == reference
        assert source.read_bytes() == raw
        records.append(dict(
            source=str(source), source_sha256=expected_hash,
            extract_offset=first["page_offset"], extract_length=len(extract),
            extract_sha256=sha256(extract), corrected_sha256=sha256(corrected),
            findings=len(evidence["findings"]), inspected_pages=evidence["inspected_pages"],
            selected_names=names, rows=len(arrow), oracle_values_bits_nulls_order_equal=True,
            corrected_pyroquet_dump_matches_reference=True,
            arrow_schema=str(arrow.schema), duck_schema=str(duck.schema),
            fastparquet_dtypes=str(frame.dtypes), commands=commands,
        ))
    report = dict(
        versions=dict(fastparquet=fastparquet.__version__, pyarrow=pyarrow.__version__,
                      duckdb=duckdb.__version__),
        loader=str(loader), loader_sha256=sha256(loader.read_bytes()), records=records,
    )
    (output / "page-adjudication-replay.json").write_text(json.dumps(report, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=ROOT.parent / "fastparquet/test-data")
    parser.add_argument("--loader", type=Path, default=ROOT / "build/three-way-20260918/next-load")
    parser.add_argument("--output", type=Path, default=ROOT / "build/coverage-ledger/reproducers")
    args = parser.parse_args()
    report = replay(args.source_dir, args.loader, args.output)
    print(json.dumps([{key: record[key] for key in ("source", "findings", "inspected_pages")}
                      for record in report["records"]], indent=2))


if __name__ == "__main__":
    main()
