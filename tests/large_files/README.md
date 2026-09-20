# Large-file baseline tools

Run from repo root with `build/oracle-uv/bin/python`. Originals read-only.
Local manifests/evidence/snapshots → ignored `benchmarks/large-files`,
`profiling/large-files`, `build/large-files`, `docs/private/investigations`.

```sh
build/oracle-uv/bin/python tests/large_files/inventory.py
build/oracle-uv/bin/python tests/large_files/select.py
build/oracle-uv/bin/python tests/large_files/build.py
build/oracle-uv/bin/python tests/large_files/run.py --out new-baseline --rounds 6
build/oracle-uv/bin/python tests/large_files/validate.py --out new-validation
build/oracle-uv/bin/python tests/large_files/page_shapes.py
build/oracle-uv/bin/python tests/large_files/instrument.py
```

Inventory reads every footer before selection. `manifest.json` freezes ordered
projections, whole-file SHA256, rows, selected compressed bytes, output budgets.
Selected originals: EMBER-2017 training, NF-UQ-NIDS-V2, LUFlow. Rejected EMBER-concat
cohort retained separately; never silently reintroduce. Small controls, UNSW,
Infil1 and frozen dependency source come from retained Snappy-0.1.0 cohort;
that cohort must exist. Production unchanged.

`run.py`: fresh evidence directory; verify input hashes; randomize serialized
cases/engines; pin one CPU; one warmup + one timed full materialization/process;
six rounds default. Pyroquet destruction outside timing. Arrow materializes full
Table; DuckDB fetches full Arrow Table including connection setup/close.
Fastparquet validates only. Hash reads/untimed load warm caches: no controlled
cold-cache measurements. Linux `wait4` → peak process RSS; `/proc` I/O → lower
bounds including startup/warmup. Swapping/visible foreign CPU activity → retained
but excluded samples. PID namespaces limit visibility; runner also compares
pinned-CPU busy time against child CPU time.

Alternate binary: `--engines pyroquet --binary PATH`. Paired randomized trials,
same manifest/lifecycle: `--candidate PATH --engines pyroquet --out paired-NAME`.
Candidates implement `load.mojo` CLI. `build.py --out build/another-cohort` freezes
current source with same isolated dependencies; rejects snapshot reuse with
different source. Never rebuild accepted comparison binary in place. Match
assertion modes.

Validation exports full Pyroquet result to temporary columns, exits, compares
every value against Arrow/DuckDB in 65,536-row chunks: integer types, nulls, order,
exact float bits for Arrow. DuckDB NaN payloads outside scope. Fastparquet loads
one column at a time; row-group API cannot bound huge single groups. Its NaN/null
ambiguity stays explicit. Export buffer bounded; library still materializes
selected table. Failures/oracle exceptions never passes.

Instrumentation touches disposable frozen source only. Timers/printing perturb
execution; phase times explain, do not establish baseline throughput. Before
interpretation: `validate.py --binary build/large-files/profile-load --out profile-validation --cases ...`.
Page-header encoding counts separate from decoded level-run counts.

Preserved 2026-09-18 cohort: `docs/private/investigations/large-file-baseline-20260918.md`.
Existing baseline must not be rebuilt in place. Example rebuild:
`build.py --out build/large-files-rebuild`, then
`run.py --binary build/large-files-rebuild/load --out rebuild-trials`.

Additional evidence, serially after measurements:

```sh
build/oracle-uv/bin/python tests/large_files/profile_validate.py
build/oracle-uv/bin/python tests/large_files/profile.py
build/oracle-uv/bin/python tests/large_files/summarize.py
```

`oracle_exceptions.json`: documented fixture-hash/version/error-specific
Fastparquet failure only; result `known_failure_not_pass`. Unexpected exception
or mismatch fails validation. First unclassified failure retained with reviewed
rerun. Hardware profiles sample user cycles, not wall-time fractions.
Massif commands/raw captures in `profiling/large-files` distinguish heap
interception (misses direct mappings) from virtual mapped-page accounting.
