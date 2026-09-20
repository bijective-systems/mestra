"""Keeping a group this reader must not interpret.

Section 12 gives a file a `private` group for a producer's own
records, and section 28 lets a version add groups an older reader
does not know. Both must be ignored, not failed on, and a reader
that rewrites a file should not silently drop them. This module
copies such a group into memory as it stands and puts it back
unchanged.

Nothing here interprets what it copies. Dimension scales inside a
copied group are copied as plain datasets, and attachments between
them are not preserved, because a reader that does not know the
group does not know which of its datasets are scales either.
"""

from __future__ import annotations

from typing import Any

import h5py
import numpy as np

from .names import MACHINERY

__all__ = ["capture", "restore"]


def capture(group: h5py.Group) -> dict[str, Any]:
    """Copy a group, its attributes and its members, into memory."""
    out: dict[str, Any] = {"attrs": _attrs(group), "members": {}}
    for name, member in group.items():
        if isinstance(member, h5py.Group):
            out["members"][name] = ("group", capture(member))
        else:
            out["members"][name] = ("dataset", _dataset(member))
    return out


def _attrs(obj: Any) -> dict[str, tuple[Any, Any]]:
    out = {}
    for name in obj.attrs:
        if name in MACHINERY:
            continue
        out[name] = (obj.attrs[name], obj.attrs.get_id(name).dtype)
    return out


def _dataset(dset: h5py.Dataset) -> dict[str, Any]:
    return {
        "attrs": _attrs(dset),
        "dtype": dset.dtype,
        "shape": dset.shape,
        "maxshape": dset.maxshape,
        "chunks": dset.chunks,
        "compression": dset.compression,
        "compression_opts": dset.compression_opts,
        "shuffle": dset.shuffle,
        "fletcher32": dset.fletcher32,
        "data": dset[()] if dset.size else np.zeros(dset.shape,
                                                    dset.dtype),
    }


def restore(parent: h5py.Group, name: str,
            captured: dict[str, Any]) -> h5py.Group:
    """Write a captured group back under `parent`."""
    group = parent.create_group(name)
    _put_attrs(group, captured["attrs"])
    for member, (kind, body) in captured["members"].items():
        if kind == "group":
            restore(group, member, body)
        else:
            _put_dataset(group, member, body)
    return group


def _put_attrs(obj: Any, attrs: dict[str, tuple[Any, Any]]) -> None:
    for name, (value, dtype) in attrs.items():
        obj.attrs.create(name, value, dtype=dtype)


def _put_dataset(group: h5py.Group, name: str,
                 body: dict[str, Any]) -> None:
    kw: dict[str, Any] = {}
    if body["chunks"] is not None:
        kw["chunks"] = body["chunks"]
    if body["maxshape"] != body["shape"]:
        kw["maxshape"] = body["maxshape"]
    if body["compression"] is not None:
        kw["compression"] = body["compression"]
        kw["compression_opts"] = body["compression_opts"]
    if body["shuffle"]:
        kw["shuffle"] = True
    if body["fletcher32"]:
        kw["fletcher32"] = True
    dset = group.create_dataset(name, shape=body["shape"],
                                dtype=body["dtype"], data=body["data"],
                                track_times=False, **kw)
    _put_attrs(dset, body["attrs"])
