"""Headers for selected chunks; level-run distributions only after decompression."""
from pathlib import Path
from collections import Counter
import json,struct
import fastparquet
from fastparquet.cencoding import NumpyIO,ThriftObject
from fastparquet.compression import decompress_data
P=Path('benchmarks/large-files');out=[]
# Narrow originals + representative wide column and nullable retained control.
manifest=json.loads((P/'manifest.json').read_text())['cases']
excluded=json.loads((P/'excluded-ember-concat.json').read_text())
for c in [x for x in manifest if x['case'] in ['ember-narrow','nf-narrow','luflow-narrow','Repo dictionary/nulls']]+excluded[:1]:
 fp=fastparquet.ParquetFile(c['path']);item=dict(case=c['case'],path=c['path'],columns=[])
 for name in c['selected_names']:
  ci=fp.columns.index(name);shapes=Counter();levels=Counter();ids=Counter();sizes=[];mismatches=[]
  with open(c['path'],'rb') as f:
   for group in fp.row_groups:
    md=group.columns[ci].meta_data;offset=md.dictionary_page_offset if md.dictionary_page_offset is not None else md.data_page_offset;end=offset+md.total_compressed_size
    while offset<end:
     f.seek(offset);stream=NumpyIO(f.read(min(65536,end-offset)));h=ThriftObject.from_buffer(stream,'PageHeader');hs=stream.tell();payload=offset+hs;offset=payload+h.compressed_page_size;assert offset<=end
     d=h.data_page_header if h.type==0 else h.data_page_header_v2 if h.type==3 else None
     shapes[(h.type,d.encoding if d else None)]+=1;sizes.append([h.compressed_page_size,h.uncompressed_page_size])
     if h.type not in (0,3):continue
     f.seek(payload);raw=f.read(h.compressed_page_size)
     if h.type==0:
      body=bytes(decompress_data(raw,h.uncompressed_page_size,md.codec));n=struct.unpack_from('<I',body)[0];start=4+n;lev=body[4:start]
     else:
      start=d.definition_levels_byte_length+d.repetition_levels_byte_length
      body=raw[:start]+bytes(decompress_data(raw[start:],h.uncompressed_page_size-start,md.codec)) if d.is_compressed is not False else raw
      lev=body[d.repetition_levels_byte_length:start]
     pos=0;present=0;counts=0
     while pos<len(lev):
      v=0;shift=0
      while True:
       byte=lev[pos];pos+=1;v|=(byte&127)<<shift;shift+=7
       if byte<128:break
      if v&1:
       count=(v>>1)*8;levels['packed_runs']+=1;levels['packed_declared_values']+=count
       b=lev[pos:pos+(v>>1)];pos+=v>>1;take=min(count,d.num_values-counts);present+=sum((b[i//8]>>(i%8))&1 for i in range(take));counts+=take
      else:
       count=v>>1;value=lev[pos];pos+=1;levels['repeated_runs']+=1;levels['repeated_values']+=count;present+=count*(value&1);counts+=count
     if d.encoding in (2,8):
      stream=body[start:];bw=stream[0];pos_id=1;counted=0
      while pos_id<len(stream):
       head=0;shift=0
       while True:
        byte=stream[pos_id];pos_id+=1;head|=(byte&127)<<shift;shift+=7
        if byte<128:break
       if head&1:
        count=(head>>1)*8;pos_id+=(head>>1)*bw;kind='packed'
       else:
        count=head>>1;pos_id+=(bw+7)//8;kind='repeated'
       used=min(count,present-counted);assert used>=0 and pos_id<=len(stream)
       ids[kind+'_runs']+=1;ids[kind+'_values']+=used;counted+=used
      assert counted==present
     if d.encoding==0:
      width=8 if md.type==5 else 4;expected=present*width;actual=len(body)-start
      if actual!=expected:mismatches.append(dict(rows=d.num_values,present=present,expected=expected,actual=actual,delta=actual-expected))
  item['columns'].append(dict(name=name,page_counts=[dict(type=k[0],encoding=k[1],count=v) for k,v in shapes.items()],level_runs=dict(levels),dictionary_id_runs=dict(ids),page_sizes=sizes,plain_size_mismatches=mismatches))
 out.append(item)
Path('profiling/large-files/page-shapes.json').write_text(json.dumps(out,indent=2))
print([(x['case'],[(c['name'],c['page_counts'],c['level_runs'],len(c['plain_size_mismatches'])) for c in x['columns']]) for x in out])
