"""The dictionary codec of SPEC.md sections 17 and 25.

A callable's dictionary maps to an HDF5 group so that every language
round-trips it identically: a nested dictionary is a subgroup, a
numeric array is a dataset with a dimension scale on each axis, and a
number, a boolean or a string is an attribute on the enclosing group.
A zero-dimensional array is written as the number it holds, because
no rule that preserved it as an array could round-trip in MATLAB and
C++ as well as in Python.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

import h5py
import numpy as np

from .encoding import (
    NULL_SENTINEL,
    decode_string,
    encode_strings,
    is_fixed_string,
    make_scale,
    nest,
    read_attr,
    string_dtype,
    write_attr,
    write_raw_string_attr,
)
from .errors import MestraError
from .names import MACHINERY, RESERVED_PREFIX, is_legal_name

__all__ = ["encode_dict", "decode_dict", "ALLOWED_DTYPES"]

#: Section 25: the dtypes a dictionary dataset may have.
ALLOWED_DTYPES = ("int8", "int32", "int64", "float64")

_TOP_LEVEL_RESERVED = ("type", "repr")


def _sorted_keys(d: Mapping[str, Any]) -> list[str]:
    """Ascending order of the keys' UTF-8 bytes (section 25)."""
    return sorted((str(k) for k in d), key=lambda k: k.encode("utf-8"))


# ------------------------------------------------------------- writing

def encode_dict(group: h5py.Group, d: Mapping[str, Any],
                top_level: bool = True) -> None:
    """Write a dictionary into `group` (sections 17 and 25)."""
    for key in _sorted_keys(d):
        value = d[key]
        if not is_legal_name(key):
            raise MestraError(
                "E33", "a dictionary key must be a legal netCDF-4 "
                "name", key)
        if key.startswith(RESERVED_PREFIX):
            raise MestraError(
                "E33", "a dictionary key must not begin with %s"
                % RESERVED_PREFIX, key)
        if top_level and key in _TOP_LEVEL_RESERVED:
            raise MestraError(
                "E32", "type and repr are the container's attributes "
                "on the callable's group, so a dictionary may not use "
                "them at its top level", key)
        _encode_value(group, key, value)


def _encode_value(group: h5py.Group, key: str, value: Any) -> None:
    if isinstance(value, Mapping):
        encode_dict(group.create_group(key), value, top_level=False)
        return
    if value is None:
        write_raw_string_attr(group, key, NULL_SENTINEL)
        return
    if isinstance(value, (bool, np.bool_, int, np.integer, float,
                          np.floating, str)):
        if isinstance(value, str) and "\x00" in value:
            raise MestraError(
                "E32", "a string holding a NUL byte is not "
                "representable", key)
        write_attr(group, key, value)
        return
    if isinstance(value, (list, tuple)):
        _encode_array(group, key, _list_to_array(key, list(value)))
        return
    if isinstance(value, np.ndarray):
        if value.ndim == 0:
            # Section 25: a zero-dimensional array is the number it
            # holds, written as an attribute.
            write_attr(group, key, value.reshape(-1)[0].item()
                       if value.dtype != np.int8
                       else bool(value.reshape(-1)[0]))
            return
        _encode_array(group, key, value)
        return
    raise MestraError(
        "E32", "a value of type %s is not representable"
        % type(value).__name__, key)


def _list_to_array(key: str, values: list[Any]) -> np.ndarray:
    """A list as section 25 allows it, or a refusal (E32)."""
    if not values:
        # An empty list with no element type known.
        return np.zeros((0,), dtype="<f8")
    if all(isinstance(v, str) for v in values):
        return np.array(values, dtype=np.str_)
    if any(isinstance(v, (Mapping, str)) or v is None for v in values):
        raise MestraError(
            "E32", "a list of dictionaries, a list mixing numbers and "
            "strings and a list of nulls are not representable", key)
    try:
        array = np.array(values)
    except ValueError:
        array = np.array(None, dtype=object)
    if array.dtype == object:
        raise MestraError(
            "E32", "a ragged or mixed nested list is not "
            "representable", key)
    return array


def _encode_array(group: h5py.Group, key: str, value: Any) -> None:
    array = np.asarray(value)
    if array.dtype.kind in "USO" or is_fixed_string(array.dtype):
        _encode_strings(group, key, array)
        return
    if array.dtype == np.bool_:
        array = array.astype("<i1")
    name = array.dtype.name
    if name == "int8":
        pass
    elif name not in ALLOWED_DTYPES:
        raise MestraError(
            "E32", "%s is not one of the dtypes a dictionary may hold "
            "(%s and fixed-length strings)"
            % (name, ", ".join(ALLOWED_DTYPES)), key)
    dset = _create(group, key, array, array.dtype.newbyteorder("<"),
                   array.shape)
    _attach_scales(group, key, dset, array.shape)


def _encode_strings(group: h5py.Group, key: str, array: Any) -> None:
    flat = [v.decode("utf-8") if isinstance(v, bytes) else str(v)
            for v in np.asarray(array).reshape(-1)]
    for value in flat:
        if "\x00" in value:
            raise MestraError(
                "E32", "a string holding a NUL byte is not "
                "representable", key)
    raw, size = encode_strings(flat)
    shape = tuple(int(n) for n in np.asarray(array).shape)
    dset = _create(group, key, nest(raw, shape), string_dtype(size),
                   shape)
    _attach_scales(group, key, dset, shape)


def _create(group: h5py.Group, key: str, data: Any, dtype: Any,
            shape: Any) -> h5py.Dataset:
    shape = tuple(int(n) for n in shape)
    empty = 0 in shape
    return group.create_dataset(
        key, shape=shape, dtype=dtype, data=data, track_times=False,
        # Section 25: every zero-length axis is created with an
        # unlimited maximum, so that the dimension is legal.
        maxshape=(None,) * len(shape) if empty else None,
        chunks=(1,) * len(shape) if empty else None)


def _attach_scales(group: h5py.Group, key: str, dset: h5py.Dataset,
                   shape: Any) -> None:
    for axis, length in enumerate(shape):
        scale = make_scale(group, "%s%s_d%d" % (RESERVED_PREFIX, key,
                                                axis),
                           int(length), unlimited=(length == 0))
        dset.dims[axis].attach_scale(scale)


# ------------------------------------------------------------- reading

def decode_dict(group: h5py.Group, top_level: bool = True
                ) -> dict[str, Any]:
    """Read back the dictionary stored in `group`.

    Every member and every attribute whose name begins with
    `mestra_` is skipped, and so are the machinery attributes of
    section 18. At the top level `type` and `repr` are the
    container's and are not entries of the dictionary.
    """
    out: dict[str, Any] = {}
    for name in group.attrs:
        if name in MACHINERY or name.startswith(RESERVED_PREFIX):
            continue
        if top_level and name in _TOP_LEVEL_RESERVED:
            continue
        out[name] = read_attr(group, name)
    for name, member in group.items():
        if name.startswith(RESERVED_PREFIX):
            continue
        if isinstance(member, h5py.Group):
            out[name] = decode_dict(member, top_level=False)
        else:
            out[name] = decode_array(member)
    return out


def decode_array(dset: h5py.Dataset) -> Any:
    """One dictionary dataset as the value it holds (section 25)."""
    if dset.ndim == 0:
        raise MestraError(
            "E32", "a zero-dimensional dataset must be written as an "
            "attribute", dset.name)
    values = dset[()]
    if is_fixed_string(dset.dtype):
        flat = [decode_string(v) for v in np.asarray(values).reshape(-1)]
        if dset.ndim == 1:
            return flat
        return np.array(flat, dtype=np.str_).reshape(dset.shape)
    array = np.asarray(values)
    if array.dtype == np.int8:
        # int8 means boolean inside a dictionary (section 25).
        return array.astype(bool)
    return array
