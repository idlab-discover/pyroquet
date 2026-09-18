# Large-file baseline tools

Run from the repository root with `build/oracle-uv/bin/python`. Originals are read-only. Local manifests, evidence and snapshots remain in ignored `benchmarks/large-files`, `profiling/large-files`, `build/large-files`, and `docs/private/investigations`.

```sh
build/oracle-uv/bin/python tests/large_files/inventory.py
build/oracle-uv/bin/python tests/large_files/select.py
build/oracle-uv/bin/python tests/large_files/build.py
build/oracle-uv/bin/python tests/large_files/run.py --out new-baseline --rounds 6
build/oracle-uv/bin/python tests/large_files/validate.py --out new-validation
build/oracle-uv/bin/python tests/large_files/page_shapes.py
build/oracle-uv/bin/python tests/large_files/instrument.py
```

The inventory reads every footer before selection; `manifest.json` fixes literal ordered projections, complete-file SHA-256, rows, selected compressed bytes and output budgets. The selected-original cohort uses EMBER-2017 training, NF-UQ-NIDS-V2 and LUFlow. The rejected EMBER-concat cohort is retained separately; it must not be silently reintroduced. Existing small controls, UNSW and Infil1 are inherited from the retained Snappy-0.1.0 comparison. The frozen dependency source comes from that retained cohort, which must exist. No production implementation is modified.

`run.py` refuses to overwrite an evidence directory, verifies input hashes, randomizes serialized cases/engines, pins one CPU, records one warmup and one timed full materialization per process, and runs six rounds by default. Pyroquet's output destruction is outside timing. Arrow reads a full Table; DuckDB fetches a full Arrow Table, including connection setup/close. Fastparquet is a validation oracle, not a throughput comparator. Hash reads and an untimed load warm caches; these are not controlled cold-cache measurements. Linux `wait4` gives process peak RSS, while `/proc` I/O observations are lower bounds and include warmup/startup. Samples with observed swapping or visible foreign CPU activity are retained but excluded. PID namespaces can limit foreign-process visibility; the current runner also compares pinned-CPU busy time with child CPU time.

Use `--engines pyroquet --binary PATH` for another binary. Use `--candidate PATH --engines pyroquet --out paired-NAME` to randomize paired baseline/candidate trials with the same manifest and lifecycle. Candidate binaries must implement `load.mojo`'s CLI. `build.py --out build/another-cohort` freezes the current source, retaining the same isolated dependency imports; it rejects reuse of a snapshot containing different source. Never rebuild an accepted binary in place for a comparison. Keep assertion modes matched.

Validation exports a full Pyroquet result to temporary column files, exits, then compares every value in 65,536-row chunks against Arrow and DuckDB, including integer types, null locations, row order and exact float bits for Arrow. DuckDB NaN payloads are outside scope. Fastparquet materializes one column at a time (its row-group API cannot bound huge single groups); its float NaN/null ambiguity is explicit. The export buffer is bounded, but the library still materializes the selected table. Failures and oracle exceptions are recorded, never counted as passes.

Instrumentation modifies only a disposable frozen source copy. Its timers and printing perturb execution; phase times are explanatory evidence, not baseline throughput. Validate the instrumented binary using `validate.py --binary build/large-files/profile-load --out profile-validation --cases ...` before interpreting it. Keep page header encoding counts distinct from decoded level-run counts.

For the preserved 2026-09-18 cohort, read `docs/private/investigations/large-file-baseline-20260918.md`. The baseline already exists: rebuilding requires a new output directory, for example `build.py --out build/large-files-rebuild`, followed by `run.py --binary build/large-files-rebuild/load --out rebuild-trials`.

Additional evidence commands, run serially after measurements:

```sh
build/oracle-uv/bin/python tests/large_files/profile_validate.py
build/oracle-uv/bin/python tests/large_files/profile.py
build/oracle-uv/bin/python tests/large_files/summarize.py
```

`oracle_exceptions.json` permits only a previously documented fixture-hash/version/error-specific Fastparquet failure. Its result remains `known_failure_not_pass`; an unexpected exception or mismatch fails validation. The first unclassified failure is retained alongside its reviewed rerun. Hardware profiles sample user cycles and do not measure wall-time fractions. Massif commands/raw captures in `profiling/large-files` distinguish ordinary heap interception (incomplete for direct mappings) from virtual mapped-page accounting.
