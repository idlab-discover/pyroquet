"""Read-only metadata adjudication evidence; requires the development oracle env.

This probe describes declarations and bounded page-header scans. It does not
validate/decompress bodies, establish full file validity, or grant a parity pass.
"""
from pathlib import Path

import fastparquet
from fastparquet.cencoding import NumpyIO, ThriftObject

_MAX_CHUNK_BYTES = 64 * 1024 * 1024
_MAX_PAGES = 100_000


def _scan_pages(path, column):
    metadata = column.meta_data
    if column.file_path:
        return {"status": "unresolved", "reason": "external column chunk"}
    offsets = [value for value in (metadata.data_page_offset,
                                  metadata.dictionary_page_offset,
                                  metadata.index_page_offset) if value is not None]
    size = metadata.total_compressed_size
    if not offsets or min(offsets) < 4 or not 0 <= size <= _MAX_CHUNK_BYTES:
        return {"status": "unresolved", "reason": "offset/size outside probe bounds"}
    start = min(offsets)
    if start + size > path.stat().st_size - 8:
        return {"status": "unresolved", "reason": "chunk exceeds file envelope"}
    with path.open("rb") as source:
        source.seek(start)
        data = source.read(size)
    stream = NumpyIO(data)
    headers = compressed = uncompressed = pages = data_values = 0
    page_records = []
    try:
        while stream.tell() < len(data):
            if pages >= _MAX_PAGES:
                raise ValueError("page count outside probe bound")
            before = stream.tell()
            header = ThriftObject.from_buffer(stream, "PageHeader")
            header_size = stream.tell() - before
            if header_size <= 0 or header.type not in (0, 1, 2, 3):
                raise ValueError("invalid page header")
            if header.compressed_page_size < 0 or header.uncompressed_page_size < 0:
                raise ValueError("negative page size")
            end = stream.tell() + header.compressed_page_size
            if end > len(data):
                raise ValueError("page exceeds declared chunk")
            headers += header_size
            compressed += header.compressed_page_size
            uncompressed += header.uncompressed_page_size
            if header.type == 0:
                data_values += header.data_page_header.num_values
            elif header.type == 3:
                data_values += header.data_page_header_v2.num_values
            record = {"offset": start + before, "header_bytes": header_size,
                      "type": header.type, "compressed_page_size": header.compressed_page_size,
                      "uncompressed_page_size": header.uncompressed_page_size,
                      "crc": header.crc}
            for field in ("data_page_header", "data_page_header_v2", "dictionary_page_header"):
                detail = getattr(header, field)
                if detail is not None:
                    names = {"data_page_header": ("num_values", "encoding", "definition_level_encoding", "repetition_level_encoding"),
                             "data_page_header_v2": ("num_values", "num_nulls", "num_rows", "encoding", "definition_levels_byte_length", "repetition_levels_byte_length", "is_compressed"),
                             "dictionary_page_header": ("num_values", "encoding", "is_sorted")}[field]
                    record[field] = {name: getattr(detail, name) for name in names}
                    if field != "dictionary_page_header" and detail.statistics is not None:
                        record[field]["statistics_null_count"] = detail.statistics.null_count
            page_records.append(record)
            pages += 1
            stream.seek(end)
    except Exception as error:
        return {"status": "unresolved", "reason": str(error), "pages_scanned": pages, "page_records": page_records}
    return {"status": "complete", "pages": pages, "page_records": page_records, "header_bytes": headers,
            "compressed_body_bytes": compressed, "uncompressed_body_bytes": uncompressed,
            "compressed_with_headers": compressed + headers,
            "uncompressed_with_headers": uncompressed + headers,
            "data_page_num_values": data_values,
            "column_uncompressed_matches_pages": uncompressed + headers == metadata.total_uncompressed_size,
            "column_values_match_pages": data_values == metadata.num_values}


def inspect_metadata_evidence(path):
    """Return JSON primitives for declarations and page-header evidence at path."""
    path = Path(path)
    parquet = fastparquet.ParquetFile(path)
    groups = []
    for index, group in enumerate(parquet.row_groups):
        columns = []
        for column in group.columns:
            metadata = column.meta_data
            if metadata is None:
                columns.append({"page_scan": {"status": "unresolved", "reason": "column metadata unavailable"}})
                continue
            columns.append({"path": list(metadata.path_in_schema),
                            "declared_uncompressed": metadata.total_uncompressed_size,
                            "declared_compressed": metadata.total_compressed_size,
                            "declared_num_values": metadata.num_values,
                            "page_scan": _scan_pages(path, column)})
        complete_metadata = all("declared_uncompressed" in column for column in columns)
        uncompressed = sum(column["declared_uncompressed"] for column in columns) if complete_metadata else None
        compressed = sum(column["declared_compressed"] for column in columns) if complete_metadata else None
        scans = [column["page_scan"] for column in columns]
        complete_scan = all(scan["status"] == "complete" for scan in scans)
        groups.append({"index": index, "num_rows": group.num_rows,
                       "declared_total_byte_size": group.total_byte_size,
                       "sum_column_uncompressed": uncompressed, "sum_column_compressed": compressed,
                       "total_matches_column_uncompressed": group.total_byte_size == uncompressed,
                       "total_matches_column_compressed": group.total_byte_size == compressed,
                       "page_totals": {key: sum(scan[key] for scan in scans) for key in
                           ("pages", "header_bytes", "compressed_body_bytes", "uncompressed_body_bytes",
                            "compressed_with_headers", "uncompressed_with_headers")}
                           if complete_scan else None,
                       "columns": columns})
    created_by = parquet.fmd.created_by
    findings = []
    spec = "../parquet-format/src/main/thrift/parquet.thrift"
    if parquet.fmd.num_rows != sum(group.num_rows for group in parquet.row_groups):
        findings.append({"rule": "footer_rows_equal_sum_row_group_rows",
                         "disposition": "confirmed_invalid_metadata",
                         "spec_refs": [spec + ":1058", spec + ":1426"],
                         "reason": "File row count disagrees with row-group row counts."})
    for group in groups:
        if group["sum_column_uncompressed"] is not None and not group["total_matches_column_uncompressed"]:
            findings.append({"rule": "row_group_uncompressed_total_matches_columns",
                             "row_group": group["index"],
                             "disposition": "confirmed_invalid_metadata",
                             "spec_refs": [spec + ":925", spec + ":1055"],
                             "reason": "Row-group uncompressed total disagrees with uncompressed column sizes; neither zero nor compressed-size substitution is specified."})
        for column in group["columns"]:
            scan = column["page_scan"]
            if scan["status"] == "complete" and not scan["column_uncompressed_matches_pages"]:
                findings.append({"rule": "column_uncompressed_total_matches_page_headers_and_bodies",
                                 "row_group": group["index"], "column": column["path"],
                                 "disposition": "confirmed_invalid_metadata",
                                 "spec_refs": [spec + ":834", spec + ":925"],
                                 "reason": "Column uncompressed size disagrees with page-header declared body sizes plus measured headers."})
            elif scan["status"] != "complete":
                findings.append({"rule": "complete_bounded_page_scan", "row_group": group["index"],
                                 "column": column.get("path"), "disposition": "unresolved",
                                 "spec_refs": [spec + ":837", spec + ":928"],
                                 "reason": scan["reason"]})
    return {"scope": "metadata declarations and page headers; no body validation or parity claim",
            "findings": findings,
            "metadata_disposition": "confirmed_invalid_metadata" if any(f["disposition"] == "confirmed_invalid_metadata" for f in findings) else "not_adjudicated",
            "path": str(path), "fastparquet_version": fastparquet.__version__,
            "created_by": created_by.decode("utf-8", "replace") if isinstance(created_by, bytes) else created_by,
            "footer_num_rows": parquet.fmd.num_rows,
            "sum_row_group_rows": sum(group.num_rows for group in parquet.row_groups),
            "footer_rows_match_groups": parquet.fmd.num_rows == sum(group.num_rows for group in parquet.row_groups),
            "row_groups": groups}
