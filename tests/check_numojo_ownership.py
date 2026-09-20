"""Compile-time gates for NuMojo column borrows, with a valid control."""
from pathlib import Path
import subprocess
from check_storage_ownership import ROOT

PRELUDE='''from pyroquet.numojo_io import NumojoUInt32Column
from numojo.routines.creation import empty

def column() raises -> NumojoUInt32Column:
    var values = empty[DType.uint32]([1])
    values.unsafe_ptr()[unsafe_offset=0] = 7
    return NumojoUInt32Column(values^, List[UInt8](), "x", 0)
'''
CASES={
'valid':(True,'''def main() raises:
    var c = column()
    print(c.values().unsafe_ptr()[unsafe_offset=0])
'''),
'mutate_values':(False,'''def main() raises:
    var c = column()
    c.values().unsafe_ptr()[unsafe_offset=0] = 8
'''),
'mutate_validity':(False,'''def main() raises:
    var c = column()
    var bits = c.validity()
    bits[0] = 0
'''),
'escape_validity':(False,'''def escape() raises -> Span[UInt8, ImmStaticOrigin]:
    var c = column()
    return c.validity()

def main() raises:
    print(len(escape()))
'''),
'escape_values':(False,'''def escape() raises -> Pointer[UInt32, ImmStaticOrigin]:
    var c = column()
    return c.values().unsafe_ptr()

def main() raises:
    print(escape()[unsafe_offset=0])
'''),
'copy_column':(False,'''def main() raises:
    var c = column()
    var another = c.copy()
    print(another.size())
'''),
}

def main():
    out=ROOT/'build/numojo-ownership';out.mkdir(parents=True,exist_ok=True)
    for dtype in ('int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'int64', 'uint64', 'float16', 'float32', 'float64'):
      prelude = PRELUDE.replace('import NumojoUInt32Column', 'import NumericColumn').replace('NumojoUInt32Column', f'NumericColumn[DType.{dtype}]').replace('DType.uint32', f'DType.{dtype}')
      for name,(valid,source) in CASES.items():
        name = dtype + '-' + name
        source = source.replace('Pointer[UInt32,', f'Pointer[Scalar[DType.{dtype}],')
        path=out/(name+'.mojo');path.write_text(prelude+'\n'+source)
        r=subprocess.run(['pixi','run','mojo','build','-I','src','-I','../NuMojo',str(path),'-o',str(out/name)],cwd=ROOT,text=True,capture_output=True)
        (out/(name+'.log')).write_text(r.stdout+r.stderr)
        assert (r.returncode==0)==valid,(name,r.stdout,r.stderr)
        if not valid:assert 'error:' in r.stderr
        print('PASS',name,flush=True)
    for dtype in ('bool',):
        path = out / (dtype + '-unsupported.mojo')
        path.write_text('from pyroquet.numojo_io import load_numeric\ndef main() raises:\n    _ = load_numeric[DType.' + dtype + '] ("unused", "x")\n')
        r = subprocess.run(['pixi', 'run', 'mojo', 'build', '-I', 'src', '-I', '../NuMojo', str(path), '-o', str(out / dtype)], cwd=ROOT, text=True, capture_output=True)
        (out / (dtype + '-unsupported.log')).write_text(r.stdout + r.stderr)
        assert r.returncode != 0 and 'Unsupported numeric dtype' in r.stderr, r.stderr
        print('PASS', dtype, 'unsupported', flush=True)
if __name__=='__main__':main()
