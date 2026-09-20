"""Reading a mestra file.

`read(path)` returns a `Dataset` having read attributes and
dataspaces only: the row count, the keys with their roles and
bounds, the supports with their ids, and every slot with its
attributes. Values are read when they are asked for, and a row range
of one slot is read without touching any other slot, which is what
section 29 requires.

Pass `lazy=False` to read every value at once and close the file.
"""

from __future__ import annotations

from typing import Any

import h5py

from . import opaque
from .callables import callable_from_dict
from .codec import decode_dict
from .encoding import (
    attribute_names,
    is_fixed_string,
    read_attr,
    scale_names,
    string_length,
    support_digest,
)
from .errors import MestraError
from .model import (
    ArraySlot,
    CategoryTable,
    Dataset,
    FileSource,
    Key,
    MemorySource,
    ScalarSlot,
    Storage,
    Support,
)
from .names import logical_dimension

__all__ = ["read", "support_ids"]

_ROOT_ATTRS = ("format", "writer", "created", "aligned",
               "generalisation_group")
_ROOT_GROUPS = ("keys", "scalars", "categories", "supports",
                "callables", "notes", "private")
_KEY_ATTRS = ("role", "units", "lower", "upper", "category",
              "trajectory_group", "parent")
_SLOT_ATTRS = ("role", "varies", "units", "components", "source",
               "output", "statistic", "of", "quantile", "category",
               "recomputed", "derived_from", "recipe", "reference")
_SUPPORT_ATTRS = ("kind", "n_nodes", "n_cells", "support_id")
_SUPPORT_MEMBERS = ("node", "cell", "cell_plus_one", "index", "row",
                    "cell_types", "cell_offsets", "cell_connectivity",
                    "coordinates", "node_arrays", "cell_arrays")


def read(path: str, lazy: bool = True) -> Dataset:
    """Open a mestra file and return the dataset it holds.

    With `lazy` true, which is the default, no array is read until
    it is asked for and the file stays open; close it with
    `dataset.close()` or use the dataset as a context manager.
    """
    handle = h5py.File(path, "r")
    try:
        dataset = _read(handle, lazy)
    except Exception:
        handle.close()
        raise
    dataset.path = str(path)
    if lazy:
        dataset._file = handle
    else:
        handle.close()
    return dataset


def support_ids(path: str) -> dict[str, str]:
    """The digest of section 24 for every support in a file.

    This is the cross-file identity check of section 8: same support
    is an id comparison and not an array comparison. It reads a
    support's own arrays and nothing else, and it does not look at
    the file's major version, because the digest is defined over
    bytes and not over what they mean.
    """
    out: dict[str, str] = {}
    with h5py.File(str(path), "r") as f:
        if "supports" not in f:
            return out
        for name, group in f["supports"].items():
            if not isinstance(group, h5py.Group):
                continue
            kind = (read_attr(group, "kind") if "kind" in group.attrs
                    else "mesh")
            cells = [group[which][()] if which in group else None
                     for which in ("cell_types", "cell_offsets",
                                   "cell_connectivity")]
            if kind != "mesh":
                cells = [None, None, None]
            axis = None
            if kind == "axis" and "coordinates" in group:
                axis = group["coordinates"][()]
            out[name] = support_digest(
                read_attr(group, "n_nodes") if "n_nodes" in group.attrs
                else 0, cells[0], cells[1], cells[2], axis)
    return out


def _read(f: h5py.File, lazy: bool) -> Dataset:
    ds = Dataset(writer="", created="")
    _read_root(f, ds)
    ds.n_rows = _row_count(f)
    ds.stored_row_count = ds.n_rows
    _read_categories(f, ds, lazy)
    _read_keys(f, ds, lazy)
    _read_scalars(f, ds, lazy)
    if "row_support" in f and isinstance(f["row_support"], h5py.Dataset):
        ds._row_support = _source(f, "/row_support", lazy)
    _read_supports(f, ds, lazy)
    _read_callables(f, ds)
    if "notes" in f:
        ds.present.add("notes")
        for name in attribute_names(f["notes"]):
            ds.notes[name] = read_attr(f["notes"], name)
    _read_unknown_groups(f, ds)
    return ds


# ----------------------------------------------------------------- root

def _read_root(f: h5py.File, ds: Dataset) -> None:
    names = attribute_names(f)
    if "format" not in names:
        raise MestraError("E01", "the root attribute format is missing",
                          "/")
    ds.format = read_attr(f, "format")
    major = _major(ds.format)
    if major != 0:
        raise MestraError(
            "E01", "this reader accepts mestra/0 and the file says %r"
            % ds.format, "/")
    ds.writer = read_attr(f, "writer") if "writer" in names else ""
    ds.created = read_attr(f, "created") if "created" in names else ""
    if "aligned" in names:
        ds.stored_aligned = bool(read_attr(f, "aligned"))
    if "generalisation_group" in names:
        ds.generalisation_group = read_attr(f, "generalisation_group")
    for name in names:
        if name not in _ROOT_ATTRS:
            ds.extra[name] = read_attr(f, name)


def _major(text: str) -> int | None:
    """The major version of a `format` string, or None."""
    if not isinstance(text, str) or not text.startswith("mestra/"):
        return None
    tail = text[len("mestra/"):]
    return int(tail) if tail.isdigit() else None


def _row_count(f: h5py.File) -> int:
    """The row count, from the `row` scale (section 21)."""
    if "row" in f and isinstance(f["row"], h5py.Dataset):
        return int(f["row"].shape[0])
    for group in ("keys", "scalars"):
        if group in f:
            for member in f[group].values():
                if isinstance(member, h5py.Dataset):
                    return int(member.shape[0])
    return 0


# ----------------------------------------------------------- the pieces

def _source(f: h5py.File, path: str, lazy: bool) -> Any:
    """A source for one dataset, lazy or read at once."""
    dset = f[path]
    decode = is_fixed_string(dset.dtype)
    source = FileSource(f, path, dset.shape, dset.dtype, decode)
    if lazy:
        return source
    return MemorySource(source.read())


def _storage(dset: h5py.Dataset) -> Storage:
    return Storage(chunks=dset.chunks,
                   gzip=(dset.compression_opts
                         if dset.compression == "gzip" else None),
                   shuffle=bool(dset.shuffle),
                   contiguous=dset.chunks is None)


def _dims(dset: h5py.Dataset, fallback: tuple[str, ...]
          ) -> tuple[str, ...]:
    """The logical dimension names, taken from the scales.

    A reader takes a dimension's name from the scale's link name and
    never from its NAME attribute (section 21). When an axis carries
    no scale, which is a broken file (E25), the names the slot's own
    attributes imply are used instead.
    """
    names = scale_names(dset)
    if any(len(axis) != 1 for axis in names):
        return fallback
    return tuple(logical_dimension(axis[0]) for axis in names)


def _extra(obj: Any, known: tuple[str, ...]) -> dict[str, Any]:
    return {name: read_attr(obj, name) for name in attribute_names(obj)
            if name not in known}


def _read_categories(f: h5py.File, ds: Dataset, lazy: bool) -> None:
    if "categories" not in f:
        return
    ds.present.add("categories")
    for name, dset in f["categories"].items():
        if not isinstance(dset, h5py.Dataset):
            continue
        entries = [v.rstrip(b"\x00").decode("utf-8", errors="replace")
                   if isinstance(v, bytes) else str(v)
                   for v in dset[()]]
        ds.categories[name] = CategoryTable(
            entries, itemsize=string_length(dset.dtype))


def _read_keys(f: h5py.File, ds: Dataset, lazy: bool) -> None:
    if "keys" not in f:
        return
    ds.present.add("keys")
    for name, dset in f["keys"].items():
        if not isinstance(dset, h5py.Dataset):
            continue
        attrs = attribute_names(dset)
        key = Key(
            name,
            read_attr(dset, "role") if "role" in attrs else "",
            units=read_attr(dset, "units") if "units" in attrs else None,
            lower=read_attr(dset, "lower") if "lower" in attrs else None,
            upper=read_attr(dset, "upper") if "upper" in attrs else None,
            category=(read_attr(dset, "category")
                      if "category" in attrs else None),
            trajectory_group=(read_attr(dset, "trajectory_group")
                              if "trajectory_group" in attrs else None),
            parent=read_attr(dset, "parent") if "parent" in attrs
            else None,
            data=_source(f, "/keys/" + name, lazy),
            itemsize=string_length(dset.dtype),
            extra=_extra(dset, _KEY_ATTRS))
        ds.keys[name] = key


def _slot_attrs(obj: Any) -> dict[str, Any]:
    attrs = attribute_names(obj)
    out = {name: read_attr(obj, name) for name in attrs
           if name in _SLOT_ATTRS}
    out["extra"] = _extra(obj, _SLOT_ATTRS)
    return out


def _read_scalars(f: h5py.File, ds: Dataset, lazy: bool) -> None:
    if "scalars" not in f:
        return
    ds.present.add("scalars")
    for name, member in f["scalars"].items():
        got = _slot_attrs(member)
        slot = ScalarSlot(
            name, units=got.get("units"),
            source=got.get("source", "data"), output=got.get("output"),
            statistic=got.get("statistic"), of=got.get("of"),
            quantile=got.get("quantile"), extra=got["extra"])
        if isinstance(member, h5py.Dataset):
            slot.data = _source(f, "/scalars/" + name, lazy)
            slot.storage = _storage(member)
        ds.scalars[name] = slot


def _read_supports(f: h5py.File, ds: Dataset, lazy: bool) -> None:
    if "supports" not in f:
        return
    ds.present.add("supports")
    for name, group in f["supports"].items():
        if not isinstance(group, h5py.Group):
            continue
        ds.supports[name] = _read_support(f, ds, name, group, lazy)


def _read_support(f: h5py.File, ds: Dataset, name: str,
                  group: h5py.Group, lazy: bool) -> Support:
    attrs = attribute_names(group)
    support = Support(
        name,
        read_attr(group, "kind") if "kind" in attrs else "mesh",
        n_nodes=read_attr(group, "n_nodes") if "n_nodes" in attrs else 0,
        n_cells=read_attr(group, "n_cells") if "n_cells" in attrs else 0,
        stored_support_id=(read_attr(group, "support_id")
                           if "support_id" in attrs else None),
        extra=_extra(group, _SUPPORT_ATTRS))
    support.dataset = ds
    base = "/supports/" + name
    for which in ("cell_types", "cell_offsets", "cell_connectivity"):
        if which in group and isinstance(group[which], h5py.Dataset):
            support._cells[which] = _source(f, base + "/" + which, lazy)
    if "coordinates" in group:
        support.coordinates = _read_array(
            f, support, "coordinates", group["coordinates"],
            base + "/coordinates", "node", lazy)
    for which, location, into in (
            ("node_arrays", "node", support.node_arrays),
            ("cell_arrays", "cell", support.cell_arrays)):
        if which not in group:
            continue
        support.present.add(which)
        for slot_name, member in group[which].items():
            into[slot_name] = _read_array(
                f, support, slot_name, member,
                "%s/%s/%s" % (base, which, slot_name), location, lazy)
    for member_name, member in group.items():
        if member_name in _SUPPORT_MEMBERS:
            continue
        if isinstance(member, h5py.Group):
            support.opaque[member_name] = opaque.capture(member)
    return support


def _read_array(f: h5py.File, support: Support, name: str, member: Any,
                path: str, location: str, lazy: bool) -> ArraySlot:
    got = _slot_attrs(member)
    slot = ArraySlot(
        name, got.get("role", ""), varies=got.get("varies", "none"),
        components=int(got.get("components", 1)), location=location,
        units=got.get("units"), category=got.get("category"),
        recomputed=got.get("recomputed"),
        derived_from=got.get("derived_from"), recipe=got.get("recipe"),
        reference=got.get("reference"), support=support,
        source=got.get("source", "data"), output=got.get("output"),
        statistic=got.get("statistic"), of=got.get("of"),
        quantile=got.get("quantile"), extra=got["extra"])
    if isinstance(member, h5py.Dataset):
        slot.data = _source(f, path, lazy)
        slot.storage = _storage(member)
        slot.dims = _dims(member, slot.dims)
    return slot


def _read_callables(f: h5py.File, ds: Dataset) -> None:
    if "callables" not in f:
        return
    ds.present.add("callables")
    for name, group in f["callables"].items():
        if not isinstance(group, h5py.Group):
            continue
        attrs = attribute_names(group)
        kind = read_attr(group, "type") if "type" in attrs else ""
        line = read_attr(group, "repr") if "repr" in attrs else None
        ds.callables[name] = callable_from_dict(
            kind, decode_dict(group), line)


def _read_unknown_groups(f: h5py.File, ds: Dataset) -> None:
    """Keep /private and any group section 28 lets a version add.

    A reader must not interpret /private and must not require it
    (section 29); it is copied whole so that rewriting a file does
    not throw away the producer's own records.
    """
    for name, member in f.items():
        if name == "row_support" or isinstance(member, h5py.Dataset):
            continue                       # a dimension scale at root
        if name in _ROOT_GROUPS and name != "private":
            continue
        ds.opaque[name] = opaque.capture(member)


