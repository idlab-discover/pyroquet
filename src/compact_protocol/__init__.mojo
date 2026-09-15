"""Native Thrift Compact data protocol. No RPC, code generation, or Parquet dependency."""

from .protocol import (
    CompactReader,
    CompactWriter,
    CompactLimits,
    CompactType,
    FieldHeader,
    CollectionHeader,
    MapHeader,
)
