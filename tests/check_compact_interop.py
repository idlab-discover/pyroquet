"""Compare native Compact Protocol bytes with Apache Thrift, using fixed seeds."""
import hashlib
import importlib.metadata
import json
from pathlib import Path
import random
import struct
import subprocess
import uuid

from thrift.Thrift import TType
from thrift.protocol.TCompactProtocol import TCompactProtocol
from thrift.transport.TTransport import TMemoryBuffer

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/compact-interop"


def write_value(protocol, kind, value):
    methods = {
        TType.BOOL: protocol.writeBool, TType.BYTE: protocol.writeByte,
        TType.I16: protocol.writeI16, TType.I32: protocol.writeI32,
        TType.I64: protocol.writeI64, TType.DOUBLE: protocol.writeDouble,
        TType.STRING: protocol.writeBinary, TType.UUID: protocol.writeUuid,
    }
    if kind in methods:
        methods[kind](value)
    elif kind == TType.STRUCT:
        write_struct(protocol, value)
    elif kind in (TType.LIST, TType.SET):
        element_type, values = value
        begin = protocol.writeListBegin if kind == TType.LIST else protocol.writeSetBegin
        end = protocol.writeListEnd if kind == TType.LIST else protocol.writeSetEnd
        begin(element_type, len(values))
        for item in values:
            write_value(protocol, element_type, item)
        end()
    elif kind == TType.MAP:
        key_type, value_type, pairs = value
        protocol.writeMapBegin(key_type, value_type, len(pairs))
        for key, item in pairs:
            write_value(protocol, key_type, key)
            write_value(protocol, value_type, item)
        protocol.writeMapEnd()
    else:
        raise ValueError(kind)


def write_struct(protocol, fields):
    protocol.writeStructBegin("fixture")
    for field_id, kind, value in fields:
        protocol.writeFieldBegin("field", kind, field_id)
        write_value(protocol, kind, value)
        protocol.writeFieldEnd()
    protocol.writeFieldStop()
    protocol.writeStructEnd()


def read_value(protocol, kind):
    methods = {
        TType.BOOL: protocol.readBool, TType.BYTE: protocol.readByte,
        TType.I16: protocol.readI16, TType.I32: protocol.readI32,
        TType.I64: protocol.readI64, TType.DOUBLE: protocol.readDouble,
        TType.STRING: protocol.readBinary, TType.UUID: protocol.readUuid,
    }
    if kind in methods:
        return methods[kind]()
    if kind == TType.STRUCT:
        return read_struct(protocol)
    if kind in (TType.LIST, TType.SET):
        begin = protocol.readListBegin if kind == TType.LIST else protocol.readSetBegin
        end = protocol.readListEnd if kind == TType.LIST else protocol.readSetEnd
        element_type, size = begin()
        result = (element_type, [read_value(protocol, element_type) for _ in range(size)])
        end()
        return result
    if kind == TType.MAP:
        key_type, value_type, size = protocol.readMapBegin()
        result = (key_type, value_type, [(read_value(protocol, key_type), read_value(protocol, value_type)) for _ in range(size)])
        protocol.readMapEnd()
        return result
    raise ValueError(kind)


def read_struct(protocol):
    protocol.readStructBegin()
    fields = []
    while True:
        _, kind, field_id = protocol.readFieldBegin()
        if kind == TType.STOP:
            break
        fields.append((field_id, kind, read_value(protocol, kind)))
        protocol.readFieldEnd()
    protocol.readStructEnd()
    return fields


def fixtures():
    yield "all_types", [
        (-32768, TType.BOOL, True), (32767, TType.BOOL, False),
        (1, TType.BYTE, -128), (2, TType.I16, -32768),
        (3, TType.I32, -(2**31)), (4, TType.I64, -(2**63)),
        (5, TType.DOUBLE, -0.0), (6, TType.STRING, b"\x00\xff\xce\xbc"),
        (7, TType.LIST, (TType.BOOL, [True, False] * 8)),
        (8, TType.SET, (TType.I16, [-1, 0, 32767])),
        (9, TType.MAP, (TType.STRING, TType.BOOL, [(b"a", False), (b"b", True)])),
        (10, TType.STRUCT, [(1, TType.I64, 2**63 - 1)]),
        (11, TType.UUID, uuid.UUID("00112233-4455-6677-8899-aabbccddeeff")),
        (12, TType.MAP, (TType.STOP, TType.STOP, [])),
        (13, TType.LIST, (TType.STRUCT, [[], [(1, TType.BOOL, True)]])),
    ]
    rng = random.Random(20260915)
    for size in (0, 1, 7, 8, 9, 14, 15, 16, 63, 64, 65, 127, 128, 129):
        yield f"integers_{size}", [
            (1, TType.LIST, (TType.I32, [rng.randrange(-(2**31), 2**31) for _ in range(size)])),
            (20, TType.LIST, (TType.I64, [rng.randrange(-(2**63), 2**63) for _ in range(size)])),
        ]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    binary = OUT / "transcode"
    subprocess.run(["pixi", "run", "mojo", "build", "-O3", "-I", "src",
                    "tests/compact_interop.mojo", "-o", str(binary)], cwd=ROOT, check=True)
    results = {}
    for name, fields in fixtures():
        transport = TMemoryBuffer()
        write_struct(TCompactProtocol(transport), fields)
        expected = transport.getvalue()
        source, destination = OUT / (name + ".bin"), OUT / (name + ".native.bin")
        source.write_bytes(expected)
        subprocess.run([str(binary), str(source), str(destination)], check=True)
        actual = destination.read_bytes()
        assert actual == expected, name
        decoded = read_struct(TCompactProtocol(TMemoryBuffer(actual)))
        assert decoded == fields, name
        if name == "all_types":
            assert struct.pack("<d", decoded[6][2]) == struct.pack("<d", -0.0)
        results[name] = {"bytes": len(actual), "sha256": hashlib.sha256(actual).hexdigest()}
    (OUT / "manifest.json").write_text(json.dumps({
        "oracle": "Apache Thrift", "version": importlib.metadata.version("thrift"),
        "seed": 20260915, "cases": results,
    }, indent=2) + "\n")
    print(f"Verified {len(results)} Apache Thrift/native byte-exact cases: {OUT}")


if __name__ == "__main__":
    main()
