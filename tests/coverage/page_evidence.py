"""Independent byte evidence for two retained legacy golden-fixture failures.

Development-only Fastparquet Thrift/decompression adapter; level parsing below is
independent. This deliberately does not claim to validate arbitrary Parquet.
"""
from pathlib import Path
import hashlib
import json
import struct

SPEC_REFS = [
    "../parquet-format/src/main/thrift/parquet.thrift:699-707 (page num_values includes nulls)",
    "../parquet-format/README.md:178-197 (nulls, page sections, no page padding)",
    "../parquet-format/Encodings.md:50-67 (PLAIN widths)",
    "../parquet-format/Encodings.md:94-144 (hybrid run grammar)",
]
TARGETS = {
    "customer.impala.parquet": {"c_custkey", "c_nationkey", "c_acctbal"},
    "non-std-kvm.fp-0.8.2.parquet": {"a"},
}


def _levels(data, num_values):
    """Decode bounded width-one runs, preserving declared vs consumed counts."""
    if num_values < 0:
        raise ValueError("negative page value count")
    pos = count = present = 0
    runs = []
    while pos < len(data):
        head = shift = 0
        while True:
            if pos >= len(data) or shift > 28:
                raise ValueError("truncated or oversized hybrid header")
            byte = data[pos]
            pos += 1
            head |= (byte & 127) << shift
            if byte < 128:
                break
            shift += 7
        if head < 2:
            raise ValueError("zero-length hybrid run")
        length = (head >> 1) * (8 if head & 1 else 1)
        if length > 2**31 - 1:
            raise ValueError("hybrid run length exceeds specification limit")
        used = min(length, max(0, num_values - count))
        if head & 1:
            end = pos + (head >> 1)
            if end > len(data):
                raise ValueError("truncated packed levels")
            present += sum((data[pos + i // 8] >> (i % 8)) & 1 for i in range(used))
            runs.append({"kind": "packed", "count": length})
            pos = end
        else:
            if pos >= len(data) or data[pos] > 1:
                raise ValueError("invalid repeated level")
            present += used * data[pos]
            runs.append({"kind": "rle", "count": length, "value": data[pos]})
            pos += 1
        count += length
    if count < num_values:
        raise ValueError("insufficient levels")
    return runs, present


def inspect_page_evidence(path):
    """Return JSON primitives; identify only the two named fixture anomalies.

    A no_targeted_anomaly result is not a format-validity or parity pass.
    Unknown filenames receive not_targeted, with no inspection attempted.
    """
    path = Path(path)
    result = {"scope": "targeted_flat_plain_v1", "status": "not_targeted",
              "spec_refs": SPEC_REFS, "findings": [], "inspected_pages": 0}
    if path.name not in TARGETS:
        return result
    from fastparquet import ParquetFile
    from fastparquet.cencoding import NumpyIO, ThriftObject
    from fastparquet.compression import decompress_data

    pf = ParquetFile(path)
    result["source_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    result["created_by"] = pf.fmd.created_by.decode("utf8", errors="replace")
    with path.open("rb") as source:
        for gi, group in enumerate(pf.row_groups):
            for column in group.columns:
                md = column.meta_data
                if len(md.path_in_schema) != 1 or md.path_in_schema[0] not in TARGETS[path.name]:
                    continue
                name = md.path_in_schema[0]
                if pf.schema.max_definition_level(md.path_in_schema) != 1 or pf.schema.max_repetition_level(md.path_in_schema) != 0:
                    raise ValueError("targeted inspector requires optional flat columns")
                offset = md.data_page_offset
                end = offset + md.total_compressed_size
                while offset < end:
                    source.seek(offset)
                    stream = NumpyIO(source.read(min(65536, end - offset)))
                    header = ThriftObject.from_buffer(stream, "PageHeader")
                    payload = offset + stream.tell()
                    next_offset = payload + header.compressed_page_size
                    if next_offset > end:
                        raise ValueError("page exceeds chunk")
                    d = header.data_page_header
                    if header.type != 0 or d.encoding != 0 or d.definition_level_encoding != 3:
                        raise ValueError("targeted inspector requires PLAIN V1 with RLE levels")
                    source.seek(payload)
                    body = bytes(decompress_data(source.read(header.compressed_page_size), header.uncompressed_page_size, md.codec))
                    level_length = struct.unpack_from("<I", body)[0]
                    if level_length + 4 > len(body):
                        raise ValueError("level stream exceeds page")
                    levels = body[4:4 + level_length]
                    runs, present = _levels(levels, d.num_values)
                    actual = len(body) - 4 - level_length
                    expected = present * {1: 4, 2: 8, 4: 4, 5: 8}[md.type]
                    consumed = 0
                    overrun = False
                    for run in runs:
                        if run["kind"] == "rle" and consumed + run["count"] > d.num_values:
                            overrun = True
                        consumed += run["count"]
                    result["inspected_pages"] += 1
                    if overrun or actual != expected:
                        result["findings"].append({
                            "kind": "definition_rle_overrun" if overrun else "plain_surplus_bytes",
                            "adjudication_status": "unresolved_disagreement" if overrun else "invalid_fixture",
                            "spec_refs": SPEC_REFS,
                            "row_group": gi, "column": name, "page_offset": offset,
                            "payload_offset": payload, "page_end": next_offset,
                            "header_num_values": d.num_values,
                            "definition_level_bytes_hex": levels.hex(),
                            "definition_runs": runs, "present_values_bounded_to_header": present,
                            "plain_actual_bytes": actual, "plain_expected_bytes": expected,
                            "surplus_bytes_hex": body[4 + level_length + expected:].hex(),
                            "interpretation": "RLE run exceeds declared page count" if overrun else "PLAIN bytes exceed fixed-width count; page padding forbidden",
                            "uncertainty": "Spec gives RLE counts and page count but no separate explicit RLE overrun rule; no general permission to truncate RLE runs is established." if overrun else None,
                        })
                    offset = next_offset
    result["status"] = (result["findings"][0]["adjudication_status"] if result["findings"] else "no_targeted_anomaly")
    return result


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    print(json.dumps(inspect_page_evidence(args.path), indent=2))
