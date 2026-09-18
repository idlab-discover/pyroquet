"""Subprocess driver for injected codec errors and atomic publication checks."""
from std.sys import argv
from std.os import listdir
from std.os.path import exists
from numojo.routines.creation import empty
from pyroquet.numojo_io import NumericColumn, load_numeric
from pyroquet.numojo_write import NumericWriteOptions, save_numeric


def main() raises:
    var args = argv()
    if args[1] == "read":
        try:
            var column = load_numeric[DType.int32](args[2], "i32")
        except _:
            print("expected codec failure")
            return
        raise Error("Injected read failure escaped as a column")
    var values = empty[DType.int32]([3])
    for i in range(3):
        values.unsafe_ptr()[unsafe_offset=i] = Int32(i)
    var column = NumericColumn[DType.int32](values^, List[UInt8](), "i32", 0)
    try:
        save_numeric[DType.int32](
            args[2] + "/result.parquet", column, NumericWriteOptions(codec=2)
        )
    except _:
        if exists(args[2] + "/result.parquet") or len(listdir(args[2])) != 0:
            raise Error("Failed compression published or leaked staging files")
        print("expected codec failure; no destination or staging files")
        return
    raise Error("Injected write failure unexpectedly succeeded")
