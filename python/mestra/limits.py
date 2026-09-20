"""The limits this package refuses to go past.

A reader opens files it did not write. A file is a stranger: it may
declare a dataset of a thousand billion elements, nest groups thirty
thousand deep, link to another file, or name a filter no library
has. None of that is the specification's fault and none of it may
crash, hang or exhaust memory.

Every limit here is a number with a reason. They are module
attributes so that a caller who knows what it is doing can raise
them:

    import mestra
    mestra.limits.MAX_READ_ELEMENTS = 1 << 32

A limit that is reached is a refusal, never a silent truncation: the
reader raises `MestraError` with the rule `reader` and the validator
records a finding that names the path and the limit.
"""

from __future__ import annotations

__all__ = [
    "MAX_READ_ELEMENTS",
    "MAX_DEPTH",
    "MAX_OBJECTS",
    "MAX_UNITS_DEPTH",
    "MAX_UNITS_LENGTH",
    "MAX_STRING_BYTES",
]

#: The most elements one read may materialise. 2**26 float64 is half
#: a gibibyte, which is more than any corpus file and less than a
#: hostile declaration of 10**12 elements. Lazy access is not
#: limited, because a row range of a huge dataset is only as large as
#: the range; the limit is on what one call would allocate.
MAX_READ_ELEMENTS = 1 << 26

#: How deep a walk goes into groups, into a callable's dictionary,
#: and into a group this reader must copy without interpreting. A
#: file of this format is about five levels deep; a hostile one is
#: thirty thousand, which costs a naive walker a quadratic amount of
#: string building before it costs it a stack.
MAX_DEPTH = 64

#: How many objects one pass over a file visits. A file with more
#: than this is not read further and says so.
MAX_OBJECTS = 200000

#: How deep a units string may nest parentheses, and how long it may
#: be. "kg/(m s)" is one level; a string with thousands is an attack
#: on a recursive descent parser and not a unit.
MAX_UNITS_DEPTH = 32
MAX_UNITS_LENGTH = 4096

#: The longest fixed-length string this reader decodes in one go.
MAX_STRING_BYTES = 1 << 20
