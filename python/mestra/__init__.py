"""mestra: a container for simulation and surrogate data.

Rows of observations over design parameters, operating conditions
and time; scalar quantities and fields on shared supports; the claim
that rows are index-aligned, stated so a reader can check it.

    import mestra

    ds = mestra.read("run.mes")
    print(ds.n_rows, ds.aligned)
    pressure = ds.supports["s0"].node_arrays["pressure"]
    print(pressure.dims)                      # row, node, component
    print(pressure.read(slice(0, 4)).at(row=1, node=3, component=0))

    report = mestra.validate("run.mes")
    for finding in report.errors + report.warnings:
        print(finding)

This package implements SPEC.md version 0. The specification and the
conformance corpus define the format between them; no implementation
is the reference.
"""

from __future__ import annotations

from .callables import (
    Affine,
    Callable,
    OpaqueCallable,
    callable_from_dict,
    callable_types,
    keys_table,
    register_callable,
)
from .codec import decode_dict, encode_dict
from .encoding import support_digest
from .errors import Finding, MestraError
from .evaluate import evaluate
from .model import (
    ArraySlot,
    CategoryTable,
    Dataset,
    Key,
    NamedArray,
    ScalarSlot,
    Slot,
    Storage,
    Support,
)
from .reader import read, support_ids
from .validator import Report, validate
from .weights import compute_weights
from .writer import write

__version__ = "0.1.0"

#: The format version this package reads and writes.
FORMAT = "mestra/0"

__all__ = [
    "Affine",
    "ArraySlot",
    "Callable",
    "CategoryTable",
    "Dataset",
    "FORMAT",
    "Finding",
    "Key",
    "MestraError",
    "NamedArray",
    "OpaqueCallable",
    "Report",
    "ScalarSlot",
    "Slot",
    "Storage",
    "Support",
    "__version__",
    "callable_from_dict",
    "callable_types",
    "compute_weights",
    "decode_dict",
    "encode_dict",
    "evaluate",
    "keys_table",
    "read",
    "register_callable",
    "support_digest",
    "support_ids",
    "validate",
    "write",
]
