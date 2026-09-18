# Project conventions

- Keep investigations, design notes, handoffs, and profiling/benchmark reports in ignored `docs/private/`. Reserve public `docs/` for deliberately publishable documentation.
- Keep `build/`, `profiling/`, and `benchmarks/` ignored; retain experimental artifacts there locally.
- Reserve `examples/` for brief, human-friendly examples of saving and loading Parquet. Put smoke checks and test utilities in `tests/`.
- Commit atomically: each commit has one clear purpose. Commit completed increments often enough to keep changes reviewable.
- Sub-agents may be used when useful, including without an explicit delegation request.

## Implementation and parity

- Keep the library in Mojo, with a current exception for compression/decompression: external codec libraries through FFI are allowed. Keep that exception confined to codecs; Parquet parsing, encoding, storage, and scheduling remain Mojo. Mojo dependencies are allowed. Python dependencies belong only in development tools, tests/oracles, benchmarks, and profiling, not library execution. Audit the dependency path used by the library; ordinary Mojo standard-library/runtime OS services are expected.
- Check parity by running Fastparquet, DuckDB's relevant Parquet operations, and PyArrow's relevant Parquet operations against Pyroquet. Compare complete values, types, null locations, row order, and relevant metadata; distinguish NaN from null and compare floating bits when required.
- Use the local `../parquet-format` specification to resolve disagreements. Record unsupported oracle behavior or invalid fixtures explicitly; preserve fixtures and validation rather than weakening checks to obtain agreement. A skipped oracle comparison is not a pass.

## Local verification tools

- Build and test with the pinned Pixi Mojo environment; task definitions are in `pixi.toml`. Use `build/oracle-uv/bin/python` with `tests/oracle-requirements.txt` for the three independent readers. Ownership checks in `tests/` include programs that must fail compilation.
- Available CPU tools: `perf`, `valgrind` (including Callgrind/Massif), `gdb`, `objdump`, and `readelf`. Pixi also supplies `mojo-lldb`, `mojo-lldb-dap`, `lldb-server`, and `llvm-symbolizer` under `.pixi/envs/default/bin/`.
- `nsys` and `ncu` are installed for relevant GPU investigations. Verify tool permissions and hardware support before relying on a capture; installation alone does not establish usability.
- The existing `benchmarks/rewrite_phase_probe.py` measures the sibling baseline. When using it, read `docs/private/baseline-diagnostic.md` and keep historical measurements distinct from this rewrite's results.

## Performance priorities

- Target representative real-data Parquet files, primarily at least 50–100 MB on disk and larger. Inspect actual physical/logical types, codecs, page encodings and null density before selecting an optimization; distinguish whole-file size from selected compressed bytes and decoded output size.
- Judge performance by repeatable complete-load improvements on useful real workloads. All-null and nearly-all-null fixtures remain correctness coverage; their performance regressions do not veto improvements on the target workloads. Preserve valid-input semantics and malformed-input rejection for every supported case.
- Before choosing new optimization work, read ignored `docs/private/optimization-directions.md` and `docs/private/real-data-layouts.md` when available. Historical prompts are evidence, not a current implementation queue; feature additions need their own task scope.
