# Release qualification

From a bootstrapped Linux x86-64 checkout, run `pixi run check-release`, then
`pixi run check-release-large`. Both are required for candidate qualification;
the second reuses the exact exporter binary qualified by the first. Neither task
tags or publishes a release.

Every invocation preserves commands, stdout/stderr, peak RSS, compiler and runtime
hashes, pinned dependency revisions, oracle versions, source hashes, fixture
manifests and comparison reports under a new ignored `build/release/` directory.
The source tree must be committed and dependencies clean. Source/environment
changes invalidate the ordinary result before the large gate can start.

Ordinary checks include all native tests, optimized assertion-disabled acceptance
checks, compile-fail ownership checks, malformed codec tests, package builds,
golden corpus inventory and complete three-reader comparison of deterministic
small and 50–100 MiB fixtures. Large checks generate two files exceeding 1 GiB
on disk, compare complete outputs in bounded oracle batches, and record repeated
complete-load timings. Native output allocation budgets are explicit fixture
manifest fields; codec/page staging and allocator overhead are reflected in RSS.

`export.mojo` materializes the native table once and emits bounded binary records
per schema node. `parity.py` compares scalar bits, bytes, null locations, order,
LIST offsets and STRUCT validity using memory-mapped records and oracle chunks.
Fastparquet chunks are row-group-sized; generated row groups are bounded to
65,536 rows. Logical/schema agreement and value agreement are separate dimensions.
Reviewed oracle limitations and excluded invalid corpus files remain nonpasses.
Unexpected errors or mismatches fail the gate. Historical security dataset tools
under `tests/large_files/` are optional and are not part of this workflow.

For implementation iteration only:

```
build/oracle-uv/bin/python tests/release/run.py --development --skip-native
```

This permits dirty source and skips native tests. Its report cannot qualify a
candidate or authorize the large candidate gate. Choose a fresh `--out` directory
if supplying one; existing evidence reports are never overwritten.
