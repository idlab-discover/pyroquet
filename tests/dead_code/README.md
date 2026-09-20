# Function-entry audit

Development only: instrument disposable `src/` copy; production/package unchanged.
Audit-only C counter records every instrumented entry, including inlined calls.
Generic instantiations aggregate by source definition. No branch coverage,
caller/callee edges or runtime percentages. Single-threaded executables required:
non-atomic counters. Crashes may prevent exit dump; missing counters = failure,
never zero coverage.

Rewriter supports current multiline `def` signatures and triple-double-quoted
docstrings; not general Mojo parser. Compile generated source; inspect it and
`functions.json` when introducing syntax. `*Options`/`*Limits` constructors excluded:
Mojo evaluates compile-time default arguments. Aliases/compiler-generated functions
outside inventory.

Run from repo root; choose fresh output paths:

```sh
build/oracle-uv/bin/python tests/dead_code/instrument.py build/call-audit/source
pixi run mojo build -O3 -g -D ASSERT=all -I build/call-audit/source/src -I ../NuMojo tests/large_files/load.mojo -Xlinker build/call-audit/source/counter.o -o build/call-audit/load
pixi run mojo build -O3 -g -D ASSERT=all -I build/call-audit/source/src -I ../NuMojo tests/dead_code/roundtrip.mojo -Xlinker build/call-audit/source/counter.o -o build/call-audit/roundtrip
build/oracle-uv/bin/python tests/dead_code/collect.py --instrumented build/call-audit/source --reader build/call-audit/load --writer build/call-audit/roundtrip --out build/call-audit/evidence
```

Collector verifies fixture hashes; exercises all 14 large-file manifest projections.
Writes/reloads three `*-wide` originals (Snappy V1) and nullable dictionary control
(Snappy V2). Native roundtrips check complete values, float bits, nulls, order,
names, dtypes, counts, schema nullability. Self-consistency only; use large-file
validator for independent three-oracle parity. Preserve its failures/limitations.

`--cases NAME ...`: subset. `--supplemental BINARY`: instrumented single-threaded
targeted tests; counters separate from large-corpus observations. Ignored output
retains counts, commands, statuses, hashes, Parquet files and `coverage.json`.

Zero entries = **not observed in workload**. Before removal, check production
callers, public exports, dedicated tests, malformed-input paths and local Parquet
spec. Test-only old APIs are migration candidates. Numeric-corpus absence never
justifies removing required format handling.
