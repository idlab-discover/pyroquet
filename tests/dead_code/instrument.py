"""Function-entry profiling in a disposable source copy; never edit production.

Counters aggregate generic instantiations by source definition, not branches.
The native counter is profiling-only; it is not linked into library artifacts.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def prepare(out):
    out.mkdir(parents=True, exist_ok=False)
    shutil.copytree(ROOT / 'src', out / 'src')
    entries = []
    for path in sorted((out / 'src').rglob('*.mojo')):
        original = path.read_text()
        lines = original.splitlines(keepends=True)
        insertions = {}
        owner = ""
        for index, line in enumerate(lines):
            struct = re.match(r"struct (\w+)", line)
            if struct:
                owner = struct[1]
            if line.startswith("def "):
                owner = ""
            match = re.match(r'(\s*)def (\w+)', line)
            if not match:
                continue
            end = index
            while not lines[end].rstrip().endswith(':'):
                end += 1
            ident = len(entries)
            entries.append(dict(id=ident, file=str(path.relative_to(out)), line=index + 1,
                                name=match[2], owner=owner, instrumented=True, source_sha256=hashlib.sha256(original.encode()).hexdigest()))
            if match[2] == "__init__" and owner.endswith(("Options", "Limits")):
                entries[-1].update(instrumented=False, reason="Constructor evaluated for compile-time default arguments")
                continue
            indent = len(match[1]) + 4
            body = end + 1
            while not lines[body].strip():
                body += 1
            if lines[body].lstrip().startswith('"""'):
                end = body
                if lines[body].count('"""') < 2:
                    end += 1
                    while '"""' not in lines[end]:
                        end += 1
            insertions[end] = ' ' * indent + f'_ = external_call["pyroquet_audit_hit", Int32](Int32({ident}))\n'
        if insertions:
            path.write_text(''.join(
                line + insertions.get(i, '') for i, line in enumerate(lines)) + '\nfrom std.ffi import external_call\n')
    (out / 'functions.json').write_text(json.dumps(entries, indent=2))
    counter = out / 'counter.c'
    counter.write_text('''#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static uint64_t counts[@COUNT@];
int32_t pyroquet_audit_hit(int32_t id) { counts[id]++; return 0; }
__attribute__((destructor)) static void finish(void) {
    const char *path = getenv("PYROQUET_AUDIT_COUNTS");
    if (!path) return;
    FILE *f = fopen(path, "w");
    if (!f) abort();
    for (int i=0; i<@COUNT@; i++) fprintf(f, "%d %llu\\n", i, (unsigned long long)counts[i]);
    if (fclose(f)) abort();
}
'''.replace('@COUNT@', str(len(entries))))
    subprocess.run(['cc', '-O2', '-c', str(counter), '-o', str(out / 'counter.o')], check=True)
    print(f'Instrumented {sum(e["instrumented"] for e in entries)} of {len(entries)} definitions in {out}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('out', type=Path)
    prepare(parser.parse_args().out.resolve())
