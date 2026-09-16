"""Pinned-CPU release measurements, with validation inside probes outside timing."""
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import tempfile
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/binary-checks'


def main():
    cpu = min(os.sched_getaffinity(0))
    rng = random.Random(20260916)
    records = []
    for label, rows, large in [('tiny', 81, False), ('repeated', 100000, False), ('all-valid', 100000, False), ('all-null', 100000, False), ('random-tail', 20000, True)]:
        raw = [None if i % 5 == 0 else (rng.randbytes(4096 if i % 101 == 0 else i % 64) if large else b'prefix' * 5) for i in range(rows)]
        flag = [None if i % 7 == 0 else i % 2 == 0 for i in range(rows)]
        if label == 'all-valid':
            raw = [b'prefix' * 5] * rows
            flag = [i % 2 == 0 for i in range(rows)]
        elif label == 'all-null':
            raw = [None] * rows
            flag = [None] * rows
        path = OUT / f'perf-{label}.parquet'
        pq.write_table(pa.table({'flag': pa.array(flag, type=pa.bool_()), 'raw': pa.array(raw, type=pa.binary())}), path, use_dictionary=False, compression='NONE', row_group_size=65536, data_page_size=65536, write_batch_size=1024)
        for mode in ('load', 'save'):
            process = subprocess.run(['zsh', '-c', 'TIMEFMT="maxrss_kib=%M"\ntime "$@"', 'probe', 'taskset', '-c', str(cpu), str(ROOT / 'build/probe-binary-io'), mode, str(path)], capture_output=True, text=True, check=True)
            times = list(map(int, process.stdout.split()))
            peak = int(process.stderr.strip().split('=')[-1])
            retained = 3 * ((rows + 7) // 8) + (rows + 1) * 8 + sum(len(v) for v in raw if v is not None)
            records.append(dict(case=label, mode=mode, rows=rows, samples_ns=times, median_ns=statistics.median(times), peak_rss_kib=peak, retained_payload_bytes_per_table=retained))
    report = dict(affinity=cpu, seed=20260916, conditions='Hot filesystem cache, single thread, two warmups, five trials; validation excluded. RSS includes source, output, allocator retention and validation; no startup inside timer.', results=records)
    (ROOT / 'build/binary-io-performance.json').write_text(json.dumps(report, indent=2))
    for r in records:
        print(r['case'], r['mode'], r['median_ns'], r['peak_rss_kib'])


if __name__ == '__main__':
    main()
