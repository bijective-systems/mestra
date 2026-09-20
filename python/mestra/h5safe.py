"""Touching an HDF5 file that may be hostile.

Everything in this module exists because the high-level h5py calls
are not safe on a file nobody vouches for:

  - `group.items()` raises RuntimeError when any member is a cyclic
    soft link, so a reader that iterates a group that way fails on
    the whole group rather than on the one bad member;
  - indexing a group follows links, and following an external link
    opens another file, which this reader must never do;
  - `dataset.compression` reports what h5py recognises, so a filter
    with twelve client-data values or an identifier no library has
    comes back as "no filter";
  - reading a dataset whose type has no conversion path raises from
    inside the library, and a dataset may declare more elements than
    the machine has memory.

The calls here never raise for those reasons. They return what they
could read and, beside it, a plain sentence about what they could
not. Deciding what that means is the validator's business and the
reader's, not this module's.
"""

from __future__ import annotations

import contextlib
import os
from dataclasses import dataclass
from typing import Any

import h5py

from . import limits
from .encoding import decode_string as decode_bytes
from .encoding import normalise_attr as normalise
from .errors import MestraError, TooLarge
from .names import MACHINERY

__all__ = [
    "Member",
    "members",
    "hard_members",
    "attr_names",
    "attr_shape",
    "attr_type",
    "attr_value",
    "element_count",
    "too_large",
    "check_size",
    "read_values",
    "filters_of",
    "scale_names",
    "scale_index",
    "is_scale",
    "open_file",
    "decode_bytes",
]

#: The kinds of link a member can be. Only `hard` is followed.
HARD, SOFT, EXTERNAL, OTHER = "hard", "soft", "external", "other"


@dataclass
class Member:
    """One member of a group, and how safe it was to look at."""

    name: str
    kind: str
    #: The object, when it is a plain member that opened. None
    #: otherwise, and then `problem` says why and `rule` names it.
    obj: Any = None
    #: E40 for a link that is not a hard link, E41 for a member that
    #: could not be opened (section 14).
    rule: str = "E41"
    #: What a link points at, for a report. Never followed.
    target: str | None = None
    filename: str | None = None
    problem: str | None = None

    @property
    def usable(self) -> bool:
        return self.obj is not None


def members(group: h5py.Group) -> list[Member]:
    """Every member of `group`, by name, following nothing.

    Iterating a group yields names without dereferencing anything,
    which is the one traversal a cyclic link cannot break. Each name
    is then classified by its link type, and only a plain member is
    opened.
    """
    out: list[Member] = []
    try:
        names = sorted(group, key=lambda n: n.encode("utf-8", "replace"))
    except Exception as exc:                            # pragma: no cover
        return [Member("", OTHER, problem="this group cannot be "
                                          "listed: %s" % _brief(exc))]
    for name in names:
        out.append(_member(group, name))
    return out


def hard_members(group: h5py.Group) -> list[Member]:
    """The members that are plain objects and opened cleanly."""
    return [m for m in members(group) if m.usable]


def _member(group: h5py.Group, name: str) -> Member:
    try:
        link = group.get(name, getlink=True)
    except Exception as exc:
        return Member(name, OTHER, problem="this link cannot be read: "
                                           "%s" % _brief(exc))
    if isinstance(link, h5py.ExternalLink):
        # Never followed: opening it would read another file, which
        # section 29 forbids (E40).
        return Member(name, EXTERNAL, target=link.path,
                      filename=link.filename, rule="E40",
                      problem="an external link to %r in %r, which "
                              "this reader does not follow"
                              % (link.path, link.filename))
    if isinstance(link, h5py.SoftLink):
        return Member(name, SOFT, target=link.path, rule="E40",
                      problem="a soft link to %r, which this reader "
                              "does not follow, whether it resolves, "
                              "dangles or loops" % (link.path,))
    if not isinstance(link, h5py.HardLink):
        return Member(name, OTHER, rule="E40",
                      problem="a link of a kind this reader does not "
                              "know (%s)" % type(link).__name__)
    try:
        obj = group[name]
    except Exception as exc:
        return Member(name, HARD, rule="E41",
                      problem="this member cannot be opened: %s"
                              % _brief(exc))
    return Member(name, HARD, obj=obj)


# ---------------------------------------------------------- attributes

def attr_names(obj: Any) -> list[str]:
    """Attribute names, without the machinery of section 18."""
    try:
        return [n for n in obj.attrs if n not in MACHINERY]
    except Exception:                                   # pragma: no cover
        return []


def attr_shape(obj: Any, name: str) -> tuple[int, ...] | None:
    """The dataspace shape of an attribute, () for a scalar."""
    try:
        return tuple(obj.attrs.get_id(name).shape)
    except Exception:                                   # pragma: no cover
        return None


def attr_type(obj: Any, name: str) -> Any:
    """The HDF5 type of an attribute, or None if it cannot be read."""
    try:
        return obj.attrs.get_id(name).get_type()
    except Exception:                                   # pragma: no cover
        return None


def attr_value(obj: Any, name: str) -> Any:
    """An attribute's value, or None when it cannot be read.

    An attribute with a non-scalar dataspace comes back as its first
    element, because every attribute this format names has a scalar
    dataspace and the encoding rule (E19) is what reports the
    difference. A string that is not valid UTF-8 comes back with the
    bad bytes replaced, and E26 reports that.
    """
    try:
        raw = obj.attrs[name]
    except Exception:
        return None
    return normalise(raw)


# -------------------------------------------------------------- reading

def element_count(dset: h5py.Dataset) -> int:
    """How many elements a dataset declares, 0 when unreadable."""
    try:
        count = 1
        for extent in dset.shape:
            count *= int(extent)
        return count
    except Exception:                                   # pragma: no cover
        return 0


def too_large(dset: h5py.Dataset, rows: Any = None,
              limit: int | None = None) -> int | None:
    """The element count when one read would go past the limit.

    `rows` is a slice on the leading axis, as a lazy read gives it;
    only what the call would materialise is counted.
    """
    try:
        shape = tuple(int(n) for n in dset.shape)
    except Exception:                                   # pragma: no cover
        return None
    if rows is not None and shape:
        start, stop, step = rows.indices(shape[0])
        leading = max(0, (stop - start + (step - 1)) // step)
        shape = (leading,) + shape[1:]
    count = 1
    for extent in shape:
        count *= extent
    ceiling = limits.MAX_READ_ELEMENTS if limit is None else limit
    if count > ceiling:
        return count
    return None


def check_size(dset: h5py.Dataset, where: str, rows: Any = None,
               limit: int | None = None) -> None:
    """Refuse a read that would allocate more than the limit."""
    ceiling = limits.MAX_READ_ELEMENTS if limit is None else limit
    count = too_large(dset, rows, ceiling)
    if count is not None:
        raise TooLarge(
            "this read would materialise %d elements and the limit is "
            "%d; read a row range instead" % (count, ceiling),
            where, count)


def read_values(dset: h5py.Dataset, where: str = "", rows: Any = None,
                limit: int | None = None) -> Any:
    """Read a dataset, refusing a read that is too large.

    Anything the library itself refuses - a type with no conversion
    path, a filter it does not have - comes back as E41 naming the
    path, never as a failure from inside h5py. A read past the size
    limit is TooLarge, which is E41 for an eager read and something
    the validator leaves unchecked instead.
    """
    check_size(dset, where or dset.name, rows, limit)
    try:
        return dset[()] if rows is None else dset[rows]
    except MestraError:                                 # pragma: no cover
        raise
    except Exception as exc:
        raise MestraError(
            "E41", "this dataset cannot be read: %s" % _brief(exc),
            where or dset.name) from None


# -------------------------------------------------------------- filters

def filters_of(dset: h5py.Dataset) -> list[tuple[int, int, tuple, str]]:
    """Every filter on a dataset, from the creation property list.

    The high-level h5py properties report only the filters it knows,
    so an unknown identifier or one with more client-data values
    than h5py expects would come back as no filter at all.
    """
    out: list[tuple[int, int, tuple, str]] = []
    try:
        plist = dset.id.get_create_plist()
        count = plist.get_nfilters()
    except Exception:                                   # pragma: no cover
        return out
    for at in range(count):
        try:
            code, flags, values, name = plist.get_filter(at)
        except Exception:
            out.append((-1, 0, (), "a filter that cannot be read"))
            continue
        label = name.decode("utf-8", "replace") if isinstance(
            name, bytes) else str(name)
        out.append((int(code), int(flags), tuple(int(v) for v in values),
                    label))
    return out


# ------------------------------------------------------------- the rest

def is_scale(dset: Any) -> bool:
    """True for a dimension scale dataset (section 21)."""
    try:
        return dset.attrs.get("CLASS", b"") == b"DIMENSION_SCALE"
    except Exception:                                   # pragma: no cover
        return False


#: What a scale is called when the index cannot name it.
UNNAMED = "?"


def scale_index(f: Any) -> dict[int, str]:
    """Every dimension scale in a file, by its address.

    A scale reached through a dataset's DIMENSION_LIST is an object
    reference, and asking HDF5 for such an object's name makes it
    search the file's hierarchy for a path to it. On a file nested
    thirty thousand groups deep that search runs off the C stack and
    takes the process with it, which no Python code can catch. So
    the names come from a bounded walk of the file's own links, and
    a reference is matched to one by its address, which is a header
    read and not a search.

    The index is built once per open file and kept on it.
    """
    cached = getattr(f, "_mestra_scale_index", None)
    if cached is not None:
        return cached
    index: dict[int, str] = {}
    stack = [(f, 0)]
    seen = 0
    while stack:
        group, depth = stack.pop()
        if depth > limits.MAX_DEPTH or seen > limits.MAX_OBJECTS:
            continue
        for member in members(group):
            if not member.usable:
                continue
            seen += 1
            if isinstance(member.obj, h5py.Group):
                stack.append((member.obj, depth + 1))
                continue
            if not is_scale(member.obj):
                continue
            address = _address(member.obj)
            if address is not None and address not in index:
                index[address] = member.name
    with contextlib.suppress(Exception):
        f._mestra_scale_index = index
    return index


def _address(obj: Any) -> int | None:
    """An object's address in the file, or None."""
    try:
        return int(h5py.h5o.get_info(obj.id).addr)
    except Exception:                                   # pragma: no cover
        return None


def scale_names(dset: h5py.Dataset) -> list[tuple[str, ...]]:
    """The link name of every scale attached to each axis.

    An axis may carry none or several; both are E25 and neither is
    an error here. The name is the scale's link name and never its
    NAME attribute, so a scale whose NAME is missing is read the
    same as any other. A scale the index cannot name comes back as
    "?", which no rule accepts.
    """
    out: list[tuple[str, ...]] = []
    try:
        dims = dset.dims
        index = scale_index(dset.file)
    except Exception:                                   # pragma: no cover
        return out
    for dim in dims:
        axis: list[str] = []
        try:
            for at in range(len(dim)):
                address = _address(dim[at])
                axis.append(index.get(address, UNNAMED)
                            if address is not None else UNNAMED)
        except Exception:
            axis.append(UNNAMED)
        out.append(tuple(axis))
    return out


def open_file(path: str) -> h5py.File:
    """Open a file, or refuse it by rule rather than by exception."""
    if not os.path.exists(str(path)):
        raise MestraError("E01", "there is no file at this path",
                          str(path))
    try:
        return h5py.File(str(path), "r")
    except OSError as exc:
        raise MestraError(
            "E01", "this file cannot be opened as HDF5, so it is not "
            "a mestra file: %s" % _brief(exc), str(path)) from None


def _brief(exc: BaseException) -> str:
    """One line of an exception, for a finding."""
    text = str(exc).strip().split("\n")[0]
    if len(text) > 160:
        text = text[:157] + "..."
    return "%s: %s" % (type(exc).__name__, text) if text \
        else type(exc).__name__
