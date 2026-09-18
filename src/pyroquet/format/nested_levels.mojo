"""Schema-bounded level streams; values remain owned by typed materializers.

README.md Nested Encoding/Nulls/Data Pages; parquet.thrift DataPageHeaderV2:
V2 starts at row boundaries, while unindexed V1 may continue a prior row.
"""
from .hybrid import _HybridDecoder
from .pages import PageHeader
from .flat_pages import _u32


def _level_width(maximum: Int) -> Int:
    var width = 0
    var value = maximum
    while value > 0:
        width += 1
        value >>= 1
    return width


struct _NestedLevels(Movable):
    var repetitions: _HybridDecoder
    var definitions: _HybridDecoder
    var max_rep: Int
    var max_def: Int
    var remaining: Int
    var present: Int
    var rows: Int
    var start: Int
    var first: Bool
    var header: PageHeader

    def __init__(
        out self, data: List[UInt8], h: PageHeader, max_rep: Int, max_def: Int
    ) raises:
        if (
            max_rep < 0
            or max_rep > 1
            or max_def < 0
            or max_def > 32767
            or h.num_values < 0
        ):
            raise Error("Unsupported nested level maxima/count")
        var rep_start = 0
        var rep_end = 0
        var def_start: Int
        var def_end: Int
        if h.page_type == 0:
            if max_rep != 0:
                if h.repetition_level_encoding != 3:
                    raise Error(
                        "Nested reader requires hybrid repetition levels"
                    )
                rep_start = 4
                var size = Int(_u32(data, 0, len(data)))
                if size > len(data) - rep_start:
                    raise Error("Repetition levels exceed page")
                rep_end = rep_start + size
            def_start = rep_end
            def_end = rep_end
            if max_def != 0:
                if h.definition_level_encoding != 3:
                    raise Error(
                        "Nested reader requires hybrid definition levels"
                    )
                var size = Int(_u32(data, def_start, len(data)))
                def_start += 4
                if size > len(data) - def_start:
                    raise Error("Definition levels exceed page")
                def_end = def_start + size
        elif h.page_type == 3:
            rep_end = h.repetition_levels_byte_length
            def_start = rep_end
            if (
                rep_end < 0
                or rep_end > len(data)
                or h.definition_levels_byte_length < 0
                or h.definition_levels_byte_length > len(data) - rep_end
            ):
                raise Error("V2 levels exceed page")
            def_end = rep_end + h.definition_levels_byte_length
            if (max_rep == 0 and rep_end != 0) or (
                max_def == 0 and def_end != def_start
            ):
                raise Error("Unexpected levels for required/nonrepeated leaf")
        else:
            raise Error("Expected nested data page")
        self.repetitions = _HybridDecoder(
            rep_start,
            rep_end,
            _level_width(max_rep),
            h.num_values if max_rep else 0,
        )
        self.definitions = _HybridDecoder(
            def_start,
            def_end,
            _level_width(max_def),
            h.num_values if max_def else 0,
        )
        self.max_rep = max_rep
        self.max_def = max_def
        self.remaining = h.num_values
        self.present = 0
        self.rows = 0
        self.start = def_end
        self.first = True
        self.header = h

    def next(mut self, data: List[UInt8]) raises -> Tuple[Int, Int]:
        if self.remaining == 0:
            raise Error("Nested levels exhausted")
        var rep = 0
        var definition = 0
        if self.max_rep:
            rep = Int(self.repetitions.next(data))
        if self.max_def:
            definition = Int(self.definitions.next(data))
        if rep > self.max_rep or definition > self.max_def:
            raise Error("Level exceeds schema-derived maximum")
        if self.first and self.header.page_type == 3 and rep != 0:
            raise Error("V2 page must start at a row boundary")
        self.first = False
        self.remaining -= 1
        self.present += Int(definition == self.max_def)
        self.rows += Int(rep == 0)
        return rep, definition

    def finish(self) raises:
        if self.remaining != 0:
            raise Error("Missing nested levels")
        self.repetitions.finish()
        self.definitions.finish()
        if self.header.page_type == 3 and (
            self.header.num_nulls != self.header.num_values - self.present
            or self.header.num_rows != self.rows
        ):
            raise Error("V2 row/null declarations disagree with nested levels")
