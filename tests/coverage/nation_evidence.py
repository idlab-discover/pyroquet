"""Pinned, read-only evidence for nation.impala's terminal dictionary run."""
import hashlib
from pathlib import Path

from metadata_evidence import inspect_metadata_evidence

SOURCE_SHA256 = "cad29596730c8b94f44ca12f23754394ca9455f0a5b2935e1cae36696e6ddf34"
SPEC_REFS = ["../parquet-format/Encodings.md:83-86",
             "../parquet-format/Encodings.md:102-108"]


def inspect_terminal_run(width, header, packed):
    """Describe this fixture's single-byte, single packed run and no others."""
    if not 0 <= width <= 32 or not 1 <= header <= 127 or not header & 1:
        raise ValueError("expected a single-byte bit-packed run header")
    groups = header >> 1
    if not groups:
        raise ValueError("zero groups")
    expected = groups * width
    return {"dictionary_width": width, "packed_header": header,
            "packed_groups": groups, "packed_declared_values": groups * 8,
            "expected_packed_bytes": expected, "available_packed_bytes": len(packed),
            "missing_packed_bytes": max(0, expected - len(packed)),
            "packed_run_complete": len(packed) == expected}


def inspect_nation_evidence(path):
    path = Path(path)
    result = {"path": str(path), "status": "not_targeted",
              "scope": "Pinned dictionary-page run evidence, not whole-file parity",
              "findings": [], "spec_refs": SPEC_REFS}
    if path.name != "nation.impala.parquet":
        return result
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    result["sha256"] = digest
    if digest != SOURCE_SHA256:
        result["status"] = "not_adjudicated"
        result["reason"] = "hash_mismatch"
        return result
    metadata = inspect_metadata_evidence(path)
    for column in metadata["row_groups"][0]["columns"]:
        name = column["path"][0]
        if name not in ("n_name", "n_comment"):
            continue
        page = column["page_scan"]["page_records"][1]
        start = page["offset"] + page["header_bytes"]
        body = raw[start:start + page["compressed_page_size"]]
        if body[:6] != bytes.fromhex("020000003201") or len(body) != 24:
            raise ValueError("Pinned source's page framing changed")
        finding = inspect_terminal_run(body[6], body[7], body[8:])
        finding.update(column=name, physical_type="BYTE_ARRAY", codec="UNCOMPRESSED",
                       encoding="PLAIN_DICTIONARY", page_offset=page["offset"],
                       payload_offset=start, payload_bytes=len(body), payload_hex=body.hex(),
                       definition_length=2, definition_run_header=50, definition_value=1,
                       packed_header_offset=start + 7, expected_logical_values=25,
                       decoded_available_ids=[(int.from_bytes(body[8:], "little") >> (i * body[6])) & 31
                                              for i in range(25)],
                       disposition="confirmed_invalid_page_encoding", status="invalid_fixture",
                       rule="packed_run_has_all_declared_groups", spec_refs=SPEC_REFS,
                       reason="Four width-five groups require 20 packed bytes; only 16 bytes remain.")
        result["findings"].append(finding)
    result["status"] = "invalid_fixture"
    return result
