# Golden coverage ledger

Development-only evidence collection. Nothing here runs inside the library.
Original corpus files are read-only. Generated ledgers, exports, controls and
preserved fixture copies belong under ignored `build/`; adjudication reports
belong under ignored `docs/private/`.

From the repository root, build the full-table exporter and run:

```sh
build/oracle-uv/bin/python tests/coverage/full_table.py --build
build/oracle-uv/bin/python tests/coverage/ledger.py \
  --historical build/three-way-20260918 \
  --replay-numeric \
  --full-table-binary build/coverage-ledger/read-table \
  --preserve-fixtures
build/oracle-uv/bin/python -m unittest discover -s tests/coverage -p 'test_*.py' -v
```

The Python environment uses `tests/oracle-requirements.txt`. Reader compilation
uses the pinned Pixi Mojo environment. Build provenance includes source,
compiler/runtime and dependency identities. The ledger checks recorded source
and binary hashes before using an exporter with a build record.

`--corpus` defaults to `../fastparquet/test-data`. `--out` defaults to
`build/coverage-ledger`; select a fresh output directory to retain separate runs.
Discovery uses PAR1 magic, including extensionless files and dataset summaries.
`--preserve-fixtures` copies every selected original into the output directory
and refuses to overwrite an existing copy with different bytes. Do not regard
that directory as a collection of valid inputs: invalid and disputed files are
preserved too.

The historical directory is optional. When supplied, its inventory, manifest,
results and identity files are retained by hash. Numeric comparisons apply only
to the recorded selection and matching fixture SHA256. Changed files invalidate
historical comparisons, rather than inheriting a pass. Missing historical files
remain listed. `--replay-numeric` additionally requires the original executable
hash to match and compares a fresh export against the retained reference digest;
it is a replay of that frozen implementation, not a current-source build or a
fresh independent oracle run.

The full-table exporter uses current library source. It attempts all standalone
files, including those excluded by the historical numeric selector. Native
`exported` means loading and serialization completed, not parity. Each oracle
receives an independent comparison of complete values, names, types, nullability,
fixed width and order. Floating values use raw bits; nulls remain separate.
Oracle limitations, errors and mismatches remain separate outcomes. For a native
rejection, full-table oracles are `not_exercised`; historical numeric evidence
is still retained separately. Arbitrary key/value metadata and unsupported
logical/nested representations are not covered by this export contract. Footer
inspection is recorded separately and does not imply metadata parity.

Dataset summaries are inventoried without following external column references.
They do not enter standalone full-table comparisons. Writer behavior is
`not_exercised`: reading a producer's fixture does not establish Pyroquet writing.

## Dispositions and evidence

- `implementation_gap`: an observed reader rejection names unsupported behavior;
  this does not establish validity of the rest of the file.
- `invalid_fixture`: a cited specification rule and measured declarations/bytes
  establish a violation. This does not resolve every other issue in the file.
- `unresolved_disagreement`: evidence is insufficient for a normative decision.
- `not_adjudicated`: no violation established by the limited inspections; never
  a general validity pass.
- `not_exercised`: excluded, unavailable or deliberately outside that operation.

A file may have several findings: an invalid footer can coexist with a missing
codec. The summary prioritizes confirmed invalidity but retains every finding.
An oracle's acceptance is evidence of behavior, not a specification override.

`metadata_evidence.py` records declared totals and bounded page-header scans,
including actual data-page encodings (footer encoding sets are not page counts).
It does not decompress bodies. Limits or incomplete scans remain explicit.
`page_evidence.py` examines two named legacy fixtures with an independent,
bounded width-one level decoder and measured PLAIN lengths. Scope and spec
references accompany each finding. `nation_evidence.py` additionally checks the hash-pinned truncated dictionary
run fixture. No test helper is a general Parquet validator.

`replay_page_adjudication.py` reproduces the two page rejections, retains offending
page extracts and makes surgical control copies under `build/`. It requires the
retained numeric exporter; run `--help` for paths. Controls establish the cause of
a rejection, not full validity of unselected columns. Originals remain unchanged.

`ledger.json` is emitted only after the inventory finishes. An interrupted run
leaves `progress.json` with `complete: false`. The final `complete` flag means
all discovered entries were processed; it does not turn unresolved rules,
unexercised comparisons or known oracle limitations into successes.
