"""Instrument a disposable frozen source copy; never change production algorithms."""
from pathlib import Path
import shutil,subprocess,json,os,hashlib
B=Path('build/large-files').resolve();T=B/'instrumented';shutil.copytree(B/'source',T,dirs_exist_ok=True)
p=T/'src/pyroquet/numojo_io.mojo';s=p.read_text();s=s.replace('from std.memory import bitcast, unsafe_memcpy','from std.time import perf_counter_ns\nfrom std.memory import bitcast, unsafe_memcpy')
s=s.replace('    var framing = _flat_page_values(bytes, h, nullable, bitmap, output)','    var phase_start = perf_counter_ns()\n    var framing = _flat_page_values(bytes, h, nullable, bitmap, output)\n    var phase_levels = perf_counter_ns() - phase_start\n    var phase_values_start = perf_counter_ns()')
a=s.index('def _decode_numeric_page_impl[');b=s.index('\ndef _decode_numeric_page[',a)
seg=s[a:b].replace('            return 0','            var phase_values = perf_counter_ns() - phase_values_start\n            print("PHASE page", h.num_values, phase_levels, phase_values, 0, h.encoding)\n            return 0').replace('    return nulls','    var phase_values = perf_counter_ns() - phase_values_start\n    print("PHASE page", h.num_values, phase_levels, phase_values, nulls, h.encoding)\n    return nulls')
s=s[:a]+seg+s[b:]
s=s.replace('    var values = empty[dtype]([rows])','    var alloc_start = perf_counter_ns()\n    var values = empty[dtype]([rows])\n    var alloc_values = perf_counter_ns() - alloc_start\n    alloc_start = perf_counter_ns()').replace('    var output = 0\n    var null_count = 0','    var alloc_bitmap = perf_counter_ns() - alloc_start\n    print("PHASE allocation", alloc_values, alloc_bitmap)\n    var output = 0\n    var null_count = 0')
s=s.replace('            var next = cursor.next(file)','            var header_start = perf_counter_ns()\n            var next = cursor.next(file)\n            print("PHASE header", perf_counter_ns() - header_start)')
s=s.replace('            var bytes = file.read_bytes(page.header.compressed_page_size)','            var read_start = perf_counter_ns()\n            var bytes = file.read_bytes(page.header.compressed_page_size)\n            print("PHASE read", perf_counter_ns() - read_start, page.header.compressed_page_size)')
s=s.replace('            bytes = _page_body(','            var body_start = perf_counter_ns()\n            bytes = _page_body(').replace('            if page.header.page_type == 2:\n                dictionary =','            print("PHASE codec", perf_counter_ns() - body_start)\n            if page.header.page_type == 2:\n                var dict_start = perf_counter_ns()\n                dictionary =').replace('                has_dictionary = True','                print("PHASE dictionary", perf_counter_ns() - dict_start)\n                has_dictionary = True')
p.write_text(s)
p=T/'src/pyroquet/numeric_column.mojo';s=p.read_text().replace('from numojo.core.ndarray','from std.time import perf_counter_ns\nfrom numojo.core.ndarray').replace('        _check_numeric[Self.dtype]()','        var validation_start = perf_counter_ns()\n        _check_numeric[Self.dtype]()').replace('        self._values = values^','        print("PHASE publication", perf_counter_ns() - validation_start)\n        self._values = values^');p.write_text(s)
p=T/'src/pyroquet/table_io.mojo';s=p.read_text().replace('from std.sys import size_of','from std.sys import size_of\nfrom std.time import perf_counter_ns').replace('    var file = open(path, "r")','    var metadata_start = perf_counter_ns()\n    var file = open(path, "r")').replace('    var names = List[String]()','    print("PHASE metadata", perf_counter_ns() - metadata_start)\n    var names = List[String]()');p.write_text(s)
i=json.loads((B/'identity.json').read_text());cmd=i['cmd'];cmd[cmd.index(str(B/'source/src'))]=str(T/'src');cmd[-1]=str(B/'profile-load')
env=os.environ.copy();env.update(i['env'])
with (B/'profile-build.log').open('w') as f:r=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
print('profile build',r.returncode)
if r.returncode:print((B/'profile-build.log').read_text());raise SystemExit(r.returncode)

identity=dict(cmd=cmd,env=i["env"],returncode=r.returncode,source_sha256={str(p.relative_to(B)):hashlib.sha256(p.read_bytes()).hexdigest() for p in T.rglob("*.mojo")},binary_sha256=hashlib.sha256((B/"profile-load").read_bytes()).hexdigest())
(B/"profile-identity.json").write_text(json.dumps(identity,indent=2))
