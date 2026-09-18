"""Fresh current-source numeric projection parity for active golden GZIP files.

Unlike ledger --replay-numeric this rebuilds the native exporter and reruns all
three independent readers. No excluded originals or dataset summaries are read.
"""
from __future__ import annotations

import argparse
from collections import Counter
from importlib.metadata import version
import json
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from full_table import (_arrow_export, _fastparquet_export, _run, _hash,
                        build_reader, verify_reader, compare_tables)
from ledger import ROOT, EXCLUSIONS, discover, digest, fixture_exclusion, artifact


def oracle(engine, path, name, nullable):
    if engine == "pyarrow":
        return _arrow_export(pq.ParquetFile(path).read(columns=[name])), []
    if engine == "fastparquet":
        return _fastparquet_export(path, [name])
    import duckdb
    with duckdb.connect() as connection:
        connection.execute("SET threads=1")
        connection.execute("SET preserve_insertion_order=true")
        quoted = '"' + name.replace('"', '""') + '"'
        table = connection.execute(f"SELECT {quoted} FROM read_parquet(?)", [str(path)]).to_arrow_table()
    return _arrow_export(table, [nullable]), []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=ROOT.parent / "fastparquet/test-data")
    parser.add_argument("--out", type=Path, default=ROOT / "build/gzip-current-numeric")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    binary = args.out / "read-numeric"
    build_reader(binary=binary, source="tests/read_numeric.mojo")
    exclusions = {row["path"]: row for row in json.loads(EXCLUSIONS.read_text())["fixtures"]}
    records, excluded, summaries = [], [], []
    for path in discover(args.corpus):
        relative = path.relative_to(args.corpus).as_posix()
        if fixture_exclusion(relative, digest(path), exclusions):
            excluded.append(relative)
            continue
        file = pq.ParquetFile(path)
        metadata = file.metadata
        if any(metadata.row_group(i).column(j).file_path
               for i in range(metadata.num_row_groups) for j in range(metadata.num_columns)):
            summaries.append(relative)
            continue
        gzip_names = {metadata.row_group(i).column(j).path_in_schema
                      for i in range(metadata.num_row_groups) for j in range(metadata.num_columns)
                      if metadata.row_group(i).column(j).compression == "GZIP"}
        for field in file.schema_arrow:
            if field.name not in gzip_names or not (pa.types.is_integer(field.type) or pa.types.is_floating(field.type)):
                continue
            # Arrow stringifies float64 as 'double'; native CLI takes DType names.
            dtype = ("float32" if pa.types.is_float32(field.type) else
                     "float64" if pa.types.is_float64(field.type) else str(field.type))
            index = len(records)
            record = {"fixture": artifact(path), "relative": relative, "column": field.name,
                      "dtype": dtype, "scope": "current_source_numeric_projection",
                      "oracles": {engine: {"status": "not_exercised"}
                                  for engine in ("pyarrow", "duckdb", "fastparquet")}}
            run = _run([str(binary), dtype, str(path), field.name])
            for stream in ("stdout", "stderr"):
                output = args.out / f"{index:03}-{stream}.txt"
                output.write_text(run[stream])
                record[stream] = artifact(output)
            record["native"] = {key: value for key, value in run.items() if key not in ("stdout", "stderr")}
            if run["status"] == "completed":
                lines = run["stdout"].splitlines()
                rows, nulls = map(int, lines[0].split())
                values = [None if line == "null" else int(line) for line in lines[1:]]
                assert len(values) == rows and values.count(None) == nulls
                # load_numeric[dtype] checks the selected field's physical/logical
                # type. Nullability comes from the independent footer selection.
                native = dict(rows=rows, columns=[dict(name=field.name, type=dtype,
                              nullable=field.nullable, fixed_width=0, values=values)])
                for engine in record["oracles"]:
                    try:
                        exported, limitations = oracle(engine, path, field.name, field.nullable)
                        comparison = compare_tables(native, exported)
                        record["oracles"][engine] = ({"status": "limitation", "limitations": limitations,
                                                       "comparison_result": comparison}
                                                      if limitations else comparison)
                    except Exception as error:
                        record["oracles"][engine] = {"status": "error", "reason": str(error)}
            records.append(record)
            print(f"{index+1} {relative} {field.name}: {record['native']['status']}", flush=True)
    provenance = verify_reader(binary)
    result = {"complete": True, "scope": "fresh numeric GZIP projections; not complete-table parity",
              "reader": provenance, "exporter_helper": artifact(__file__),
              "oracle_versions": {name: version(name) for name in ("pyarrow", "duckdb", "fastparquet")},
              "excluded_invalid": excluded, "dataset_summaries": summaries, "records": records,
              "summary": {"projections": len(records), "native": dict(Counter(r["native"]["status"] for r in records)),
                          "oracles": {engine: dict(Counter(r["oracles"][engine]["status"] for r in records))
                                      for engine in ("pyarrow", "duckdb", "fastparquet")}}}
    (args.out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))


if __name__ == "__main__":
    main()
