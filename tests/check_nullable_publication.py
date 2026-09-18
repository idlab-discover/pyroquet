"""Late nullable dictionary failures cannot publish a column or table.

Use --column-binary built from tests/read_numeric.mojo and --table-binary
built from tests/large_files/load.mojo. Fixtures and raw failures stay in build/.
"""
import argparse
import copy
import json
import re
import subprocess
from pathlib import Path

from check_metadata import fields, parts, put, encode
from check_numeric_dictionary import dictionary, data, fixture
from check_pages import T


def table_fixture(good, bad, rows):
    f = fields()
    schema, group, _, _ = parts(f)
    put(schema[0], (5, T.I32, 2))
    schema[:] = [schema[0]]
    chunks = []
    payload = b''
    total = 0
    for name, pages in [(b'good', good), (b'bad', bad)]:
        node = [(1, T.I32, 1), (3, T.I32, 1), (4, T.STRING, name), (6, T.I32, 17)]
        schema.append(node)
        _, _, chunk, md = parts(fields())
        start = 4 + len(payload)
        raw = b''.join(p[0] for p in pages)
        unpacked = sum(p[1] for p in pages)
        for item in [(1, T.I32, 1), (2, T.LIST, (T.I32, [0, 3, 8])),
                     (3, T.LIST, (T.STRING, [name])), (4, T.I32, 0),
                     (5, T.I64, rows), (6, T.I64, unpacked),
                     (7, T.I64, len(raw)), (9, T.I64, start + len(pages[0][0])),
                     (11, T.I64, start)]:
            put(md, item)
        chunks.append(copy.deepcopy(chunk))
        payload += raw
        total += unpacked
    put(group, (1, T.LIST, (T.STRUCT, chunks)))
    put(group, (2, T.I64, total))
    put(group, (3, T.I64, rows))
    put(f, (3, T.I64, rows))
    return encode(f, payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--column-binary', required=True)
    parser.add_argument('--table-binary', required=True)
    parser.add_argument('--out', default='build/nullable-publication')
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for version in (1, 2):
        ids = [None if i % 3 == 0 else i % 2 for i in range(200)]
        bad_ids = ids.copy()
        bad_ids[-1] = 3
        first = dictionary([11, 22], 'int32')
        page = data(ids, 2, version=version, nullable=True)
        bad_page = data(bad_ids, 2, version=version, nullable=True)
        column = out / f'late-column-v{version}.parquet'
        column.write_bytes(fixture('int32', [([first, page], 200),
                                            ([first, page, bad_page], 400)], True))
        table = out / f'late-table-v{version}.parquet'
        table.write_bytes(table_fixture([first, page, page], [first, page, bad_page], 400))
        # The first selected column and the first data page of the second column
        # succeed. The final real ID fails after private writes have occurred.
        commands = [([args.column_binary, 'int32', str(column), 'value'], 'column'),
                    ([args.table_binary, str(table), str(1 << 30), '0', '-', 'good', 'bad'], 'table')]
        for cmd, label in commands:
            p = subprocess.run(cmd, capture_output=True, text=True)
            (out / f'{label}-v{version}.stdout').write_text(p.stdout)
            (out / f'{label}-v{version}.stderr').write_text(p.stderr)
            assert p.returncode != 0, (cmd, p.stdout)
            assert 'Dictionary ID outside dictionary' in p.stdout + p.stderr
            assert not re.search(r'(?m)^(?:WARMUP |[0-9]+ [0-9]+$)', p.stdout), 'A failed public load returned a partial result'
            results.append(dict(command=cmd, returncode=p.returncode))
        p = subprocess.run([args.table_binary, str(table), str(1 << 30), '0', '-', 'good'], capture_output=True, text=True)
        assert p.returncode == 0 and '400 1' in p.stdout, (p.stdout, p.stderr)
    (out / 'results.json').write_text(json.dumps(results, indent=2))
    print('Late column/table publication checks passed')


if __name__ == '__main__':
    main()
