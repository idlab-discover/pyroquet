"""Substantial synthetic nested PLAIN/delta cohort, independent of native writer.

Same values, schema, NONE codec and layout requests. Random int64 values keep
selected bytes substantial in both encodings; this is a decoder cost comparison,
not a claim that delta improves random-data compression. No timings here.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
import fastparquet
from fastparquet.cencoding import NumpyIO, ThriftObject

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/nested-performance'


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    rows=1_100_000
    rng=np.random.default_rng(92741)
    lengths=rng.integers(0,17,size=rows,dtype=np.int32)
    parent_null=np.arange(rows)%31 == 0
    list_null=(np.arange(rows)%17 == 0) | parent_null
    lengths[list_null]=0
    offsets=np.zeros(rows+1,dtype=np.int32)
    offsets[1:]=np.cumsum(lengths,dtype=np.int64)
    count=int(offsets[-1])
    values=rng.integers(np.iinfo('int64').min,np.iinfo('int64').max,size=count,dtype=np.int64)
    child_null=np.arange(count)%23 == 0
    children=pa.array(values,mask=child_null)
    lists=pa.ListArray.from_arrays(offsets,children,mask=pa.array(list_null))
    scalar=pa.array(np.arange(rows,dtype=np.int64),mask=parent_null)
    structure=pa.StructArray.from_arrays([scalar,lists],names=['row_id','items'],mask=pa.array(parent_null))
    table=pa.Table.from_arrays([structure],names=['s'])
    report=dict(seed=92741,synthetic=True,versions=dict(pyarrow=pa.__version__,numpy=np.__version__,fastparquet=fastparquet.__version__),
        parent_rows=rows,child_elements=count,parent_null_count=int(parent_null.sum()),list_null_count=int(list_null.sum()),child_null_count=int(child_null.sum()),
        list_length_histogram={str(i):int((lengths==i).sum()) for i in range(17)},
        expected_retained_bytes=rows*8+(rows+7)//8+(rows+7)//8+(rows+7)//8+(rows+1)*8+count*8+(count+7)//8,fixtures=[])
    for shape, cohort in [('nested',table),('flat',pa.Table.from_arrays([children],names=['x']))]:
      for encoding in ('PLAIN','DELTA_BINARY_PACKED'):
        path=OUT/f'{shape}-{encoding}.parquet'
        options=dict(compression='NONE',use_dictionary=False,column_encoding=encoding,data_page_version='2.0',data_page_size=1<<20,write_batch_size=1024,row_group_size=275000,write_statistics=False)
        pq.write_table(cohort,path,**options)
        pf=fastparquet.ParquetFile(path)
        pages=[]
        with path.open('rb') as source:
            for gi,group in enumerate(pf.row_groups):
                for col in group.columns:
                    md=col.meta_data
                    pos=md.data_page_offset;end=pos+md.total_compressed_size
                    while pos<end:
                        source.seek(pos);stream=NumpyIO(source.read(min(65536,end-pos)))
                        h=ThriftObject.from_buffer(stream,'PageHeader');d=h.data_page_header_v2
                        assert h.type==3 and d.encoding == (0 if encoding=='PLAIN' else 5)
                        pages.append(dict(row_group=gi,path=md.path_in_schema,page_version=2,value_encoding=d.encoding,codec=md.codec,compressed_bytes=h.compressed_page_size,decoded_bytes=h.uncompressed_page_size,rows=d.num_rows,level_entries=d.num_values,null_entries=d.num_nulls))
                        pos+=stream.tell()+h.compressed_page_size
                    assert pos==end
        entry=dict(shape=shape,rows=cohort.num_rows,retained_bytes=report['expected_retained_bytes'] if shape=='nested' else count*8+(count+7)//8,path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),file_bytes=path.stat().st_size,
            selected_compressed_bytes=sum(p['compressed_bytes'] for p in pages),selected_decoded_bytes=sum(p['decoded_bytes'] for p in pages),writer_options=options,pages=pages)
        report['fixtures'].append(entry)
        print(path,entry['selected_compressed_bytes'],flush=True)
    (OUT/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':
    main()
