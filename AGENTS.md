# Project conventions

- Keep investigations, design notes, and profiling/benchmark reports in ignored `docs/private/`. Reserve public `docs/` for deliberately publishable documentation.
- Keep `build/`, `profiling/`, and `benchmarks/` ignored from the start; retain experimental artifacts there locally.
- Reserve `examples/` for brief, human-friendly examples of saving and loading Parquet. Put smoke checks and test utilities in `tests/`.
