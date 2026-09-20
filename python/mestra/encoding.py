"""The byte-level encodings of SPEC.md sections 18, 19, 21 and 23.

Everything that decides what a byte in the file is lives here:
attribute types, fixed-length strings, dimension scales, the chunk
default, and the support_id digest.
"""

from __future__ import annotations

import hashlib
from collections.abc import Iterable, Sequence
from typing import Any

import h5py
import numpy as np

from .errors import MestraError
from .names import MACHINERY

__all__ = [
    "DIMENSION_SCALE_NAME",
    "NULL_SENTINEL",
    "string_dtype",
    "string_length",
    "encode_strings",
    "nest",
    "is_fixed_string",
    "decode_string",
    "write_string_attr",
    "write_raw_string_attr",
    "write_bool_attr",
    "write_int_attr",
    "write_float_attr",
    "read_attr",
    "attribute_names",
    "make_scale",
    "attach",
    "scale_names",
    "default_chunk_rows",
    "default_row_chunk",
    "support_digest",
    "chunk_bytes_per_row",
]

#: Section 21: the NAME attribute of a dimension scale with no
#: coordinate variable, 53 characters, then "%10d" of the length.
DIMENSION_SCALE_NAME = "This is a netCDF dimension but not a netCDF variable."

#: Section 18: one NUL byte followed by "null", size 5.
NULL_SENTINEL = b"\x00null"

_ONE_MIB = 1048576


# --------------------------------------------------------------- strings

def string_dtype(nbytes: int) -> np.dtype:
    """Fixed-length UTF-8 with NUL padding (sections 18 and 19)."""
    return h5py.string_dtype(encoding="utf-8", length=max(1, int(nbytes)))


def string_length(dtype: np.dtype) -> int | None:
    """The declared byte length of a fixed-length string dtype."""
    info = h5py.check_string_dtype(dtype)
    if info is None:
        return None
    return info.length


def is_fixed_string(dtype: np.dtype) -> bool:
    """True for a fixed-length HDF5 string dtype."""
    return string_length(dtype) is not None


def decode_string(raw: bytes | str) -> str:
    """Strip trailing NUL bytes, then decode UTF-8 (section 18)."""
    if isinstance(raw, str):
        return raw
    return raw.rstrip(b"\x00").decode("utf-8")


def encode_strings(values: Sequence[str], size: int | None = None
                   ) -> tuple[list[bytes], int]:
    """Pad a list of strings to the size section 19 requires."""
    raw = [v.encode("utf-8") if isinstance(v, str) else bytes(v)
           for v in values]
    n = size if size is not None else max([len(r) for r in raw] + [1])
    return [r.ljust(n, b"\x00") for r in raw], n


def nest(flat: Sequence[Any], shape: Sequence[int]) -> Any:
    """A flat list as nested lists of `shape`, which is the only
    form h5py converts into a fixed-length string dataset."""
    if len(shape) <= 1:
        return list(flat)
    step = 1
    for extent in shape[1:]:
        step *= int(extent)
    return [nest(flat[at * step:(at + 1) * step], shape[1:])
            for at in range(int(shape[0]))]


# ------------------------------------------------------------ attributes

def write_string_attr(obj: Any, name: str, value: str) -> None:
    """A string attribute, encoded as section 18 requires."""
    raw = value.encode("utf-8")
    write_raw_string_attr(obj, name, raw)


def write_raw_string_attr(obj: Any, name: str, raw: bytes) -> None:
    """A string attribute from raw bytes, for the null sentinel."""
    n = max(1, len(raw))
    obj.attrs.create(name, raw.ljust(n, b"\x00"), dtype=string_dtype(n))


def write_bool_attr(obj: Any, name: str, value: bool) -> None:
    """A boolean attribute: int8, 0 or 1 and nothing else."""
    obj.attrs.create(name, np.int8(1 if value else 0))


def write_int_attr(obj: Any, name: str, value: int) -> None:
    """An integer attribute: int64, scalar dataspace."""
    obj.attrs.create(name, np.int64(value))


def write_float_attr(obj: Any, name: str, value: float) -> None:
    """A float attribute: float64, and finite when it is a bound."""
    obj.attrs.create(name, np.float64(value))


def write_attr(obj: Any, name: str, value: Any) -> None:
    """Write one attribute, choosing the encoding from the type.

    int8 is a boolean, int64 an integer, float64 a float and a
    fixed-length string a string (section 25).
    """
    if value is None:
        write_raw_string_attr(obj, name, NULL_SENTINEL)
    elif isinstance(value, (bool, np.bool_)):
        write_bool_attr(obj, name, bool(value))
    elif isinstance(value, (int, np.integer)):
        write_int_attr(obj, name, int(value))
    elif isinstance(value, (float, np.floating)):
        write_float_attr(obj, name, float(value))
    elif isinstance(value, str):
        write_string_attr(obj, name, value)
    else:
        raise MestraError(
            "E32", "an attribute of type %s is not representable"
            % type(value).__name__, name)


def read_attr(obj: Any, name: str) -> Any:
    """Read one attribute as the value its dtype declares.

    int8 is a boolean, int64 an integer, float64 a float, and a
    fixed-length string a string with its trailing NUL bytes
    stripped (sections 18 and 25). The null sentinel comes back as
    None.
    """
    raw = obj.attrs[name]
    if isinstance(raw, bytes):
        if raw == NULL_SENTINEL:
            return None
        return decode_string(raw)
    if isinstance(raw, str):
        return raw
    value = np.asarray(raw)
    if value.dtype == np.int8:
        return bool(value.reshape(-1)[0]) if value.size else False
    if value.dtype.kind in "iu":
        return int(value.reshape(-1)[0])
    if value.dtype.kind == "f":
        return float(value.reshape(-1)[0])
    return raw


def attribute_names(obj: Any) -> list[str]:
    """Attribute names, without the machinery of section 18."""
    return [n for n in obj.attrs if n not in MACHINERY]


# ------------------------------------------------------ dimension scales

def make_scale(group: h5py.Group, name: str, length: int,
               unlimited: bool = False) -> h5py.Dataset:
    """A dimension scale, written as netCDF-C writes one (21)."""
    scale = group.create_dataset(
        name, shape=(length,), dtype=">f4",
        maxshape=(None,) if unlimited else (length,),
        chunks=(1,) if unlimited else None, track_times=False)
    scale.make_scale("%s%10d" % (DIMENSION_SCALE_NAME, length))
    return scale


def attach(dset: h5py.Dataset, scales: Iterable[h5py.Dataset]) -> None:
    """Attach one scale per axis, in order."""
    for axis, scale in enumerate(scales):
        if scale is not None:
            dset.dims[axis].attach_scale(scale)


def scale_names(dset: h5py.Dataset) -> list[tuple[str, ...]]:
    """The link names of the scales attached to each axis.

    The dimension's name is the scale's link name and never its NAME
    attribute, which says the same sentence in every file (21).
    """
    names = []
    for dim in dset.dims:
        names.append(tuple(dim[i].name.rsplit("/", 1)[-1]
                           for i in range(len(dim))))
    return names


# ---------------------------------------------------------- chunk default

def chunk_bytes_per_row(itemsize: int, rest: Sequence[int]) -> int:
    """One row of a dataset in bytes, a zero extent counted as 1."""
    b = int(itemsize)
    for extent in rest:
        b *= max(1, int(extent))
    return b


def default_chunk_rows(itemsize: int, rest: Sequence[int],
                       n_rows: int) -> int:
    """The `c` of section 23: about 1 MiB of rows, at least one,
    capped at the row count, and 1 when there are no rows."""
    if n_rows == 0:
        return 1
    c = _ONE_MIB // chunk_bytes_per_row(itemsize, rest)
    if c < 1:
        c = 1
    if c > n_rows:
        c = n_rows
    return c


def default_row_chunk(itemsize: int, shape: Sequence[int],
                      n_rows: int) -> tuple[int, ...]:
    """The whole default chunk shape of a row-dimensioned dataset."""
    rest = tuple(int(e) for e in shape[1:])
    return (default_chunk_rows(itemsize, rest, n_rows),) + rest


# ------------------------------------------------------------ support_id

def support_digest(n_nodes: int, cell_types: Any = None,
                   cell_offsets: Any = None, cell_connectivity: Any = None,
                   axis_coordinates: Any = None) -> str:
    """The support_id of section 24.

    SHA-256 over n_nodes as one little-endian int64, then cell_types
    as uint8, then cell_offsets and cell_connectivity as
    little-endian int64, then, for an axis support only, the
    coordinates as little-endian float64, all in storage order with
    nothing between them. Lower-case hexadecimal, 64 characters.
    """
    digest = hashlib.sha256()
    digest.update(np.int64(n_nodes).astype("<i8").tobytes())
    if cell_types is not None:
        digest.update(np.ascontiguousarray(
            np.asarray(cell_types), dtype="<u1").tobytes())
    if cell_offsets is not None:
        digest.update(np.ascontiguousarray(
            np.asarray(cell_offsets), dtype="<i8").tobytes())
    if cell_connectivity is not None:
        digest.update(np.ascontiguousarray(
            np.asarray(cell_connectivity), dtype="<i8").tobytes())
    if axis_coordinates is not None:
        digest.update(np.ascontiguousarray(
            np.asarray(axis_coordinates), dtype="<f8").tobytes())
    return digest.hexdigest()
