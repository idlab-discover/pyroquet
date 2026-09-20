The optional development corpus is acquired from
https://github.com/dask/fastparquet at revision
`f4beb59382e584354c4b2ef2c7a42efa4e97f024`.

Its original Apache-2.0 license is preserved in `FASTPARQUET-LICENSE`.
`../fastparquet_manifest.json` records each tracked PAR1 fixture's original path,
byte count and SHA256, including dataset summaries. Fixture bytes are not
modified. Upstream fixture provenance remains in the pinned checkout.

The corpus is development and qualification data; it is not a dependency of
Pyroquet library execution. Historical exact-byte invalid-fixture exclusions
remain in `../../coverage/excluded_fixtures.json`; reviewed active disagreements
remain in `../golden_disagreements.json`. Neither category counts as a pass.
