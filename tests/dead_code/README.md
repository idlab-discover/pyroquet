# Function-entry audit

This development tool instruments a disposable copy of `src/`. Production code
and packaged libraries are unchanged. A tiny C counter linked only into the audit
executables records every instrumented function entry, including inlined calls.
Counters aggregate generic instantiations by source definition. They do **not**
measure branches, caller/callee edges, or runtime percentages. Use single-threaded
executables: the counters are deliberately non-atomic. Crashes can prevent the
exit-time counter dump; missing counters are a failure, never zero coverage.

The source rewriter handles the repository's current multiline `def` signatures
and triple-double-quoted docstrings. It is not a general Mojo parser. Compile the
result, and inspect `functions.json` and the generated source when applying it to
new syntax. Constructors of `*Options` and `*Limits` are explicitly excluded
because Mojo evaluates them for compile-time default arguments. Aliases and
compiler-generated functions are outside the definition inventory.

Run from the repository root, choosing new output paths:

```sh
build/oracle-uv/bin/python tests/dead_code/instrument.py build/call-audit/source
pixi run mojo build -O3 -g -D ASSERT=all -I build/call-audit/source/src -I ../NuMojo tests/large_files/load.mojo -Xlinker build/call-audit/source/counter.o -o build/call-audit/load
pixi run mojo build -O3 -g -D ASSERT=all -I build/call-audit/source/src -I ../NuMojo tests/dead_code/roundtrip.mojo -Xlinker build/call-audit/source/counter.o -o build/call-audit/roundtrip
build/oracle-uv/bin/python tests/dead_code/collect.py --instrumented build/call-audit/source --reader build/call-audit/load --writer build/call-audit/roundtrip --out build/call-audit/evidence
```

The collector verifies fixture hashes and exercises all 14 large-file manifest
projections. It also writes and reloads the three `*-wide` originals and the
nullable dictionary control. Large writes use Snappy V1; the control uses Snappy
V2. Full native roundtrips check values, floating-point bits, null locations, row
order, names, dtypes, counts, and schema nullability. This is self-consistency
validation, not independent three-oracle parity. Use the existing large-file
validator for independent evidence, and preserve its limitations/failures.

`--cases NAME ...` selects a subset. `--supplemental BINARY` adds an instrumented
single-threaded executable containing targeted tests. Its counters stay separate
from large-corpus observations. Raw counts, commands, statuses, hashes, generated
Parquet files, and `coverage.json` stay in the ignored output directory.

Zero entries mean **not observed in this workload**, not dead. Check production
callers, public exports, dedicated tests, malformed-input paths, and the local
Parquet specification before classifying candidates. Old APIs used only by tests
are migration candidates, not literally unused functions. Never remove required
format handling because a large numeric corpus did not exercise it.
