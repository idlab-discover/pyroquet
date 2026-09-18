"""Equivalent full materialization; validation is a separate command/process."""
import gc,json,sys,time
import pyarrow as pa
import pyarrow.parquet as pq
import duckdb
c=json.load(open('benchmarks/large-files/manifest.json'))['cases'][int(sys.argv[2])]
engine=sys.argv[1]; names=c['selected_names'];path=c['path']
pa.set_cpu_count(1);pa.set_io_thread_count(1)
for i in range(2):
 start=time.perf_counter_ns()
 if engine=='arrow':
  with pq.ParquetFile(path,pre_buffer=False) as f:table=f.read(columns=names,use_threads=False)
 else:
  con=duckdb.connect();con.execute('SET threads=1');con.execute("SET preserve_insertion_order=true")
  table=con.execute('SELECT '+','.join('"'+n.replace('"','""')+'"' for n in names)+' FROM read_parquet(?)',[path]).to_arrow_table();con.close()
 elapsed=time.perf_counter_ns()-start
 print('WARMUP' if i==0 else 'TIME',elapsed,table.num_rows,table.num_columns,flush=True)
 del table;gc.collect()
