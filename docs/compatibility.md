# Reader compatibility

Pyroquet is checked against PyArrow, DuckDB and Fastparquet. These readers do not
expose every Parquet feature in the same way, so agreement is recorded separately
for values, types, nulls, row order and metadata. A known reader limitation is
recorded as a nonpass, never as a successful comparison.

Reports separate values/bytes, logical types, nulls, order and metadata.
DuckDB erases FLOAT16 width, fixed binary width and SQL result nullability, among
other distinctions. Fastparquet limitations: FLOAT16/ENUM exposure, fixed-byte
trailing-NUL, nested-parent validity, NaN/null, V2 dictionary/LIST.
Reviewed failures retain exact fixture hashes/reproducible controls; remain
nonpasses. Unexpected failures stop qualification.

Golden corpus: `f4beb59382e584354c4b2ef2c7a42efa4e97f024`; twelve unchanged
hash-specific invalid-fixture exclusions. Strict RLE/metadata-offset disagreements
remain nonpasses; tolerant oracles do not weaken validation. Security dataset
benchmarks/archived performance snapshots: optional local evidence. New query
optimizations outside release scope.

See the [qualification workflow](../tests/release/README.md) for how to reproduce the checks.
