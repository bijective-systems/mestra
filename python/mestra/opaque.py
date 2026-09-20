"""Keeping a group this reader must not interpret.

Section 12 gives a file a `private` group for a producer's own
records, and section 28 lets a version add groups an older reader
does not know. Both must be ignored, not failed on, and a reader
that rewrites a file should not silently drop them. This module
copies such a group into memory as it stands and puts it back
unchanged.

Nothing here interprets what it copies, and nothing here trusts it
either: the walk follows no link, goes no deeper than
`limits.MAX_DEPTH`, and copies no dataset larger than
`limits.MAX_READ_ELEMENTS`. What it could not copy is reported as a
finding and named in the dataset's `lossy` list, and `write` refuses
while any remain rather than writing the file short.

Dimension scales inside a copied group are copied as plain datasets,
and attachments between them are not preserved, because a reader
that does not know the group does not know which of its datasets are
scales either.
"""

from __future__ import annotations

from typing import Any

import h5py
import numpy as np

from . import h5safe, limits
from .errors import Finding, MestraError

__all__ = ["capture", "restore"]

#: What a member is replaced by when it could not be copied.
LOST = "mestra.opaque.lost"


def capture(group: h5py.Group, path: str = "", depth: int = 0,
            problems: list[Finding] | None = None,
            lossy: list[str] | None = None) -> dict[str, Any]:
    """Copy a group, its attributes and its members, into memory."""
    path = path or group.name
    out: dict[str, Any] = {"attrs": _attrs(group), "members": {}}
    if depth > limits.MAX_DEPTH:
        _lost(problems, lossy, path,
              "this group nests more than %d levels deep, which this "
              "reader does not follow" % limits.MAX_DEPTH)
        return out
    for member in h5safe.members(group):
        where = "%s/%s" % (path.rstrip("/"), member.name)
        if not member.usable:
            _lost(problems, lossy, where,
                  member.problem or "this member cannot be read")
            continue
        if isinstance(member.obj, h5py.Group):
            out["members"][member.name] = (
                "group", capture(member.obj, where, depth + 1,
                                 problems, lossy))
            continue
        body = _dataset(member.obj, where, problems, lossy)
        out["members"][member.name] = ("dataset", body)
    return out


def _lost(problems: list[Finding] | None, lossy: list[str] | None,
          where: str, message: str) -> None:
    if problems is not None:
        problems.append(Finding("reader", where, message))
    if lossy is not None:
        lossy.append(where)


def _attrs(obj: Any) -> dict[str, tuple[Any, Any]]:
    out = {}
    for name in h5safe.attr_names(obj):
        try:
            out[name] = (obj.attrs[name], obj.attrs.get_id(name).dtype)
        except Exception:
            continue
    return out


def _dataset(dset: h5py.Dataset, where: str,
             problems: list[Finding] | None,
             lossy: list[str] | None) -> dict[str, Any]:
    body: dict[str, Any] = {
        "attrs": _attrs(dset),
        "dtype": dset.dtype,
        "shape": dset.shape,
        "maxshape": dset.maxshape,
        "chunks": dset.chunks,
        "compression": dset.compression,
        "compression_opts": dset.compression_opts,
        "shuffle": dset.shuffle,
        "fletcher32": dset.fletcher32,
        "data": None,
    }
    try:
        body["data"] = (h5safe.read_values(dset, where) if dset.size
                        else np.zeros(dset.shape, dset.dtype))
    except MestraError as exc:
        body["data"] = LOST
        _lost(problems, lossy, where, exc.message)
    except Exception:
        body["data"] = LOST
        _lost(problems, lossy, where, "this dataset cannot be copied")
    return body


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
    if isinstance(body["data"], str) and body["data"] == LOST:
        raise MestraError(
            "reader", "this dataset could not be copied when the file "
            "was read, so it cannot be written back", name)
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
