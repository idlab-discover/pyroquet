# Golden coverage ledger

Development evidence only; no library execution. Original corpus read-only.
Generated ledgers, exports, controls and preserved fixtures → ignored `build/`.
Adjudication reports → ignored `docs/private/`.

From repo root:

```sh
build/oracle-uv/bin/python tests/coverage/full_table.py --build
build/oracle-uv/bin/python tests/coverage/ledger.py \
  --historical build/three-way-20260918 \
  --replay-numeric \
  --full-table-binary build/coverage-ledger/read-table \
  --preserve-fixtures
build/oracle-uv/bin/python -m unittest discover -s tests/coverage -p 'test_*.py' -v
```

Python: `tests/oracle-requirements.txt`. Reader: pinned Pixi Mojo. Build provenance
records source, compiler/runtime and dependencies. Exporters with build records
require matching source/binary hashes.

Defaults: `--corpus ../fastparquet/test-data`, `--out build/coverage-ledger`.
Use fresh output for separate runs. PAR1 discovery includes extensionless files
and dataset summaries. `--preserve-fixtures` copies every active selected original;
different existing bytes fail. Preserved files include invalid/disputed inputs.

Optional historical directory: inventory, manifest, results and identities retained
by hash. Numeric comparisons cover recorded selection and matching SHA256 only.
Changed bytes invalidate historical comparisons; missing files remain listed.
`--replay-numeric` also requires original executable hash; fresh export compared
against retained reference digest. Frozen implementation replay only, neither
current-source build nor fresh independent oracle run.

Current-source full-table exporter attempts all standalone files, including
historically unselected files. Native `exported` = load/serialization success only.
Each oracle independently compares complete values, names, types, nullability,
fixed width and order. Floats compared by bits; nulls separate. Oracle limitations,
errors and mismatches remain separate outcomes. Native rejection → full-table
oracles `not_exercised`; historical numeric evidence retained separately.
Arbitrary key/value metadata and unsupported logical/nested representations outside
export contract. Separate footer inspection does not establish metadata parity.

Dataset summaries: inventory only; no external column references followed,
no standalone full-table comparison. Writer `not_exercised`: producer-fixture
reads do not establish Pyroquet writing.

## Excluded invalid fixtures

`excluded_fixtures.json`: 12 adjudicated invalid originals excluded from active
coverage/parity/benchmarks. Ledger retains identities/prior findings; skips
footer/page investigation, native replay and oracles. Active counts omit exclusions;
reported separately, never passes. Preserved copies remain archival.

Exclusion requires relative path + SHA256; repaired/replaced bytes reactivate.
`customer.impala.parquet` stays active: RLE adjudication unresolved. Other corpus
consumers should select through `fixture_exclusion()` and same manifest.
Targeted malformed-input regression probes remain separate.

## Dispositions and evidence

- `implementation_gap`: observed rejection names unsupported behavior; remainder
  of file not certified valid.
- `invalid_fixture`: cited spec rule + measured declarations/bytes prove violation;
  other issues may remain.
- `unresolved_disagreement`: insufficient evidence for normative decision.
- `not_adjudicated`: limited inspection found no violation; not validity pass.
- `not_exercised`: excluded, unavailable or outside operation.

Multiple findings allowed: invalid footer may coexist with missing codec.
Summary prioritizes confirmed invalidity; retains all findings. Oracle acceptance
never overrides spec.

`metadata_evidence.py`: declared totals, bounded page-header scans, actual data-page
encodings. Footer encoding sets are not page counts. No body decompression;
limits/incomplete scans explicit. `page_evidence.py`: two named legacy fixtures,
independent bounded width-one level decoder, measured PLAIN lengths.
`nation_evidence.py`: hash-pinned truncated dictionary run. Findings retain scope
and spec references. Helpers are not general Parquet validators.

`replay_page_adjudication.py`: reproduces two page rejections; retains offending
extracts/surgical control copies under `build/`. Requires retained numeric exporter;
see `--help`. Controls establish rejection cause, not validity of unselected
columns. Originals unchanged.

`ledger.json` emitted after inventory finishes. Interrupted runs leave
`progress.json` with `complete: false`. Final `complete` means all discovered
entries processed; unresolved rules, unexercised comparisons and oracle
limitations remain nonpasses.

## Current GZIP numeric projections

```sh
build/oracle-uv/bin/python tests/coverage/current_numeric.py
```

Rebuilds `tests/read_numeric.mojo` from current source. Compares every supported
numeric GZIP column in active standalone golden files against fresh PyArrow,
DuckDB and Fastparquet reads: complete values, float bits, nulls, order.
Typed native loader validates selected physical/logical type. Nullability comes
from oracle metadata, not independent native export. Other columns, whole-table
loads and arbitrary metadata not certified. Hash-matched exclusions/external-
reference summaries explicitly omitted. Default evidence/provenance:
`build/gzip-current-numeric/`.

Exporter provenance includes pinned zlib/Mojo runtime library hashes and
source/compiler/native-Snappy identities. Audit loader resolution with
`tests/check_zlib_abi.py` and `LD_DEBUG=libs`; deployed requirements in
[root README](../../README.md#supported-values-and-storage).
