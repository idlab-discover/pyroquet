# Release qualification

Bootstrapped Linux x86-64 checkout: `pixi run check-release`, then
`pixi run check-release-large`. Both mandatory; large gate reuses exact qualified
ordinary exporter. Neither tags/publishes.

Each invocation creates fresh ignored `build/release/` evidence: commands,
stdout/stderr, peak RSS, compiler/runtime hashes, pinned dependency revisions,
oracle versions, source hashes, fixture manifests, comparison reports.
Source must be committed; dependencies clean. Source/environment changes invalidate
ordinary qualification before large gate starts.

Ordinary: all native tests, optimized assertion-disabled acceptance, ownership
compile-fail checks, malformed codecs, packages, golden corpus inventory,
complete three-reader comparison of deterministic small and 50–100 MiB fixtures.
Large: two generated files >1 GiB on disk, complete comparisons in bounded oracle
batches, repeated complete-load timings. Manifests specify native output budgets;
RSS includes codec/page staging and allocator overhead.

`export.mojo` materializes native table once; emits bounded binary records per
schema node. `parity.py` compares scalar bits, bytes, nulls, order, LIST offsets
and STRUCT validity through memory-mapped records/oracle chunks. Fastparquet
chunks follow row groups, generated with ≤65,536 rows. Logical/schema agreement
separate from value agreement. Reviewed oracle limitations/excluded invalid files
remain nonpasses. Unexpected errors/mismatches fail. Historical security dataset
tools in `tests/large_files/`: optional, outside gates.

Implementation iteration only:

```
build/oracle-uv/bin/python tests/release/run.py --development --skip-native
```

Allows dirty source; skips native tests. Cannot qualify candidate or authorize
large candidate gate. Explicit `--out` must be fresh; evidence never overwritten.
