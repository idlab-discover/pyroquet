"""Parquet wire interpretation, separate from the generic Compact codec."""

from .metadata import (
    SchemaElement,
    ColumnChunk,
    RowGroup,
    FileMetadata,
    parse_metadata,
    inspect_metadata,
    validate_file_ranges,
)
