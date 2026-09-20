"""Writing a mestra file.

`write(dataset, path)` lays the file out as sections 18 to 25
require: fixed creation order, object time tracking off, dimension
scales written as netCDF-C writes them, strings fixed-length UTF-8
with NUL padding, and arrays chunked along `row` with the non-row
extents full.

What a file said about its own layout survives a rewrite: a
non-default chunk, a compression filter, a string size larger than
its longest element, an attribute this version does not know, and a
group it must not interpret all come back out as they went in.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from typing import Any

import h5py
import numpy as np

from . import opaque
from .codec import encode_dict
from .encoding import (
    default_row_chunk,
    encode_strings,
    make_scale,
    string_dtype,
    write_attr,
    write_bool_attr,
    write_int_attr,
    write_string_attr,
)
from .errors import MestraError
from .model import ArraySlot, Dataset, Key, Support
from .names import disk_dimension

__all__ = ["write"]

_KEY_ORDER = ("role", "units", "lower", "upper", "category",
              "trajectory_group", "parent")
_ARRAY_ORDER = ("role", "varies", "units", "components", "source",
                "output", "category", "statistic", "of", "quantile",
                "recomputed", "derived_from", "recipe", "reference")
_SCALAR_ORDER = ("units", "source", "output", "statistic", "of",
                 "quantile")


def write(dataset: Dataset, path: str) -> None:
    """Write `dataset` to `path` as a mestra/0 file.

    A dataset that was read from a file with parts this reader could
    not copy is refused rather than written short: rewriting it
    would drop them silently.
    """
    if dataset.lossy:
        raise MestraError(
            "E41", "this dataset was read from a file with parts "
            "that could not be copied (%s), so writing it would lose "
            "them" % ", ".join(sorted(dataset.lossy)[:4]), str(path))
    with h5py.File(path, "w") as f:
        _write(dataset, f)


def _write(ds: Dataset, f: h5py.File) -> None:
    _root_attrs(ds, f)
    scales = _make_scales(ds, f)
    _write_categories(ds, f, scales)
    _write_keys(ds, f, scales)
    _write_scalars(ds, f, scales)
    _write_row_support(ds, f, scales)
    _write_supports(ds, f, scales)
    _write_callables(ds, f)
    if ds.notes or "notes" in ds.present:
        notes = f.create_group("notes")
        for name in sorted(ds.notes):
            write_attr(notes, name, ds.notes[name])
    for name in sorted(ds.opaque):
        opaque.restore(f, name, ds.opaque[name])
    _close(scales)


def _close(scales: _Scales) -> None:
    """Close every dataset in the order it was created.

    A chunked dataset writes its chunks when it closes, so the order
    the writer closes them in is the order their bytes land in the
    file. Closing them here, in creation order, is what makes two
    runs of this writer produce the same bytes (section 30).
    """
    for dset in scales.keep:
        dset.id.close()
    scales.keep.clear()


# ----------------------------------------------------------------- root

def _root_attrs(ds: Dataset, f: h5py.File) -> None:
    write_string_attr(f, "created", ds.created)
    write_string_attr(f, "format", ds.format)
    write_string_attr(f, "writer", ds.writer)
    write_bool_attr(f, "aligned", ds.aligned)
    if ds.generalisation_group is not None:
        write_string_attr(f, "generalisation_group",
                          ds.generalisation_group)
    for name in sorted(ds.extra):
        write_attr(f, name, ds.extra[name])


# --------------------------------------------------------------- scales

class _Scales:
    """Every dimension scale in the file, by its name on disk."""

    def __init__(self) -> None:
        self.root: dict[str, h5py.Dataset] = {}
        self.local: dict[str, dict[str, h5py.Dataset]] = {}
        #: Every dataset the writer made, held open until the file
        #: closes. A dataset that h5py closes early flushes its chunk
        #: at that moment, which changes where the bytes land.
        self.keep: list[h5py.Dataset] = []

    def of(self, support: str | None, name: str) -> h5py.Dataset:
        if support is not None:
            local = self.local.get(support, {})
            if name in local:
                return local[name]
        if name not in self.root:
            raise MestraError(
                "E25", "no dimension scale called %r; the writer "
                "should have made one" % name)
        return self.root[name]


def _make_scales(ds: Dataset, f: h5py.File) -> _Scales:
    scales = _Scales()
    scales.root["row"] = make_scale(f, "row", ds.n_rows, unlimited=True)
    for n in sorted(_component_counts(ds)):
        scales.root["component_%d" % n] = make_scale(
            f, "component_%d" % n, n)
    for n in sorted(_draw_counts(ds)):
        scales.root["draw_%d" % n] = make_scale(f, "draw_%d" % n, n)
    for key in ds.keys_of_role("group"):
        name = "group_" + key.name
        scales.root[name] = make_scale(f, name, _group_length(ds, key))
    for table in sorted(ds.categories):
        name = "category_" + table
        scales.root[name] = make_scale(f, name, len(ds.categories[table]))
    return scales


def _component_counts(ds: Dataset) -> set[int]:
    """The distinct component counts stored datasets use."""
    out = set()
    for slot in ds.slots().values():
        if isinstance(slot, ArraySlot) and slot.data is not None:
            out.add(int(slot.data.shape[-1]))
    return out


def _draw_counts(ds: Dataset) -> set[int]:
    """The distinct draw counts stored datasets use."""
    out = set()
    for slot in ds.slots().values():
        if not isinstance(slot, ArraySlot) or slot.data is None:
            continue
        if "draw" in slot.dims:
            out.add(int(slot.data.shape[slot.dims.index("draw")]))
    return out


def _group_length(ds: Dataset, key: Key) -> int:
    """The number of categories of a group key (section 21)."""
    table = ds.categories.get(key.category or key.name)
    if table is not None:
        return len(table)
    if key.data is not None and key.data.shape[0]:
        return int(np.max(key.data.read())) + 1
    return 1


# ----------------------------------------------------------- the pieces

def _dataset(group: h5py.Group, name: str, data: Any, dtype: Any,
             attached: Sequence[Any], *, row_axis: bool = False,
             n_rows: int = 0, storage: Any = None,
             keep: list[Any] | None = None) -> h5py.Dataset:
    """One dataset, with its chunking, filters and scales."""
    array = np.ascontiguousarray(data, dtype=dtype)
    kw: dict[str, Any] = {}
    chunks = storage.chunks if storage is not None else None
    if row_axis:
        kw["maxshape"] = (None,) + array.shape[1:]
        kw["chunks"] = chunks or default_row_chunk(
            array.dtype.itemsize, array.shape, n_rows)
    elif chunks:
        kw["chunks"] = chunks
    elif 0 in array.shape:
        kw["maxshape"] = (None,) * array.ndim
        kw["chunks"] = (1,) * array.ndim
    if storage is not None and storage.gzip is not None:
        kw["compression"] = "gzip"
        kw["compression_opts"] = storage.gzip
    if storage is not None and storage.shuffle:
        kw["shuffle"] = True
    dset = group.create_dataset(name, shape=array.shape, dtype=dtype,
                                data=array, track_times=False, **kw)
    for axis, scale in enumerate(attached):
        if scale is not None:
            dset.dims[axis].attach_scale(scale)
    if keep is not None:
        keep.append(dset)
    return dset


def _string_dataset(group: h5py.Group, name: str, values: Any,
                    scale: Any, *, itemsize: int | None = None,
                    row_axis: bool = False, n_rows: int = 0,
                    storage: Any = None,
                    keep: list[Any] | None = None) -> h5py.Dataset:
    """A fixed-length UTF-8 string dataset (section 19)."""
    flat = [v.decode("utf-8") if isinstance(v, bytes) else str(v)
            for v in np.asarray(values).reshape(-1)]
    raw, size = encode_strings(flat, itemsize)
    shape = (len(raw),)
    kw: dict[str, Any] = {}
    if row_axis:
        kw["maxshape"] = (None,)
        chunks = storage.chunks if storage is not None else None
        kw["chunks"] = chunks or default_row_chunk(size, shape, n_rows)
    dset = group.create_dataset(name, shape=shape,
                                dtype=string_dtype(size), data=raw,
                                track_times=False, **kw)
    if scale is not None:
        dset.dims[0].attach_scale(scale)
    if keep is not None:
        keep.append(dset)
    return dset


def _attrs(obj: Any, slot: Any, order: Iterable[str]) -> None:
    """Write a slot's attributes in the order section 19 lists."""
    for name in order:
        value = getattr(slot, name, None)
        if value is None:
            continue
        write_attr(obj, name, value)
    for name in sorted(getattr(slot, "extra", {})):
        write_attr(obj, name, slot.extra[name])


def _write_categories(ds: Dataset, f: h5py.File,
                      scales: _Scales) -> None:
    if not ds.categories and "categories" not in ds.present:
        return
    group = f.create_group("categories")
    for name in sorted(ds.categories):
        table = ds.categories[name]
        _string_dataset(group, name, table.entries,
                        scales.root["category_" + name],
                        itemsize=table.itemsize, keep=scales.keep)


def _write_keys(ds: Dataset, f: h5py.File, scales: _Scales) -> None:
    if not ds.keys and "keys" not in ds.present:
        return
    group = f.create_group("keys")
    for name in ds.key_names():
        key = ds.keys[name]
        values = key.data.read() if key.data is not None else np.zeros(0)
        if np.asarray(values).dtype.kind in "USO":
            dset = _string_dataset(group, name, values,
                                   scales.root["row"],
                                   itemsize=key.itemsize, row_axis=True,
                                   n_rows=ds.n_rows, keep=scales.keep)
        else:
            dset = _dataset(group, name, values,
                            np.asarray(values).dtype.newbyteorder("<"),
                            [scales.root["row"]], row_axis=True,
                            n_rows=ds.n_rows, keep=scales.keep)
        _attrs(dset, key, _KEY_ORDER)


def _write_scalars(ds: Dataset, f: h5py.File, scales: _Scales) -> None:
    if not ds.scalars and "scalars" not in ds.present:
        return
    group = f.create_group("scalars")
    for name in sorted(ds.scalars):
        slot = ds.scalars[name]
        if slot.data is None:
            _attrs(group.create_group(name), slot, _SCALAR_ORDER)
            continue
        values = slot.data.read()
        dset = _dataset(group, name, values,
                        np.asarray(values).dtype.newbyteorder("<"),
                        [scales.root["row"]], row_axis=True,
                        n_rows=ds.n_rows, storage=slot.storage,
                        keep=scales.keep)
        _attrs(dset, slot, _SCALAR_ORDER)


def _write_row_support(ds: Dataset, f: h5py.File,
                       scales: _Scales) -> None:
    if not ds.has_row_support:
        return
    _dataset(f, "row_support", ds.row_support, "<i4",
             [scales.root["row"]], row_axis=True, n_rows=ds.n_rows,
             keep=scales.keep)


def _write_supports(ds: Dataset, f: h5py.File, scales: _Scales) -> None:
    if not ds.supports and "supports" not in ds.present:
        return
    group = f.create_group("supports")
    for name in ds.support_names():
        _write_support(ds, group.create_group(name), ds.supports[name],
                       scales)


def _write_support(ds: Dataset, group: h5py.Group, support: Support,
                   scales: _Scales) -> None:
    local: dict[str, h5py.Dataset] = {}
    scales.local[support.name] = local
    if support.kind != "none":
        local["node"] = make_scale(group, "node", support.n_nodes)
    types = support.cell_types
    offsets = support.cell_offsets
    connectivity = support.cell_connectivity
    if types is not None:
        local["cell"] = make_scale(group, "cell", len(types))
    if offsets is not None:
        local["cell_plus_one"] = make_scale(group, "cell_plus_one",
                                            len(offsets))
    if connectivity is not None:
        local["index"] = make_scale(group, "index", len(connectivity))
    if types is not None:
        _dataset(group, "cell_types", types, "<u1", [local["cell"]],
                 keep=scales.keep)
    if offsets is not None:
        _dataset(group, "cell_offsets", offsets, "<i8",
                 [local["cell_plus_one"]], keep=scales.keep)
    if connectivity is not None:
        _dataset(group, "cell_connectivity", connectivity, "<i8",
                 [local["index"]], keep=scales.keep)
    write_string_attr(group, "kind", support.kind)
    write_int_attr(group, "n_nodes", support.n_nodes)
    write_int_attr(group, "n_cells", support.n_cells)
    write_string_attr(group, "support_id", support.support_id)
    for name in sorted(support.extra):
        write_attr(group, name, support.extra[name])

    rows_here = ds.n_rows
    if not ds.aligned and _has_row_varying(support):
        rows_here = int(len(ds.rows_on(support)))
        local["row"] = make_scale(group, "row", rows_here,
                                  unlimited=True)

    if support.coordinates is not None:
        _write_array(ds, group, "coordinates", support.coordinates,
                     scales, rows_here)
    for which, arrays in (("node_arrays", support.node_arrays),
                          ("cell_arrays", support.cell_arrays)):
        if not arrays and which not in support.present:
            continue
        sub = group.create_group(which)
        for name in sorted(arrays):
            _write_array(ds, sub, name, arrays[name], scales, rows_here)
    for name in sorted(support.opaque):
        opaque.restore(group, name, support.opaque[name])


def _has_row_varying(support: Support) -> bool:
    return any(slot.varies == "row"
               for slot in support.arrays().values())


def _write_array(ds: Dataset, group: h5py.Group, name: str,
                 slot: ArraySlot, scales: _Scales, n_rows: int) -> None:
    if slot.data is None:
        _attrs(group.create_group(name), slot, _ARRAY_ORDER)
        return
    values = np.asarray(slot.data.read())
    support = slot.support.name if slot.support is not None else None
    attached = []
    for axis, dim in enumerate(slot.dims):
        length = values.shape[axis] if axis < values.ndim else 0
        attached.append(scales.of(support, disk_dimension(dim, length)))
    dset = _dataset(group, name, values, values.dtype.newbyteorder("<"),
                    attached, row_axis=slot.dims[:1] == ("row",),
                    n_rows=n_rows, storage=slot.storage,
                    keep=scales.keep)
    _attrs(dset, slot, _ARRAY_ORDER)


def _write_callables(ds: Dataset, f: h5py.File) -> None:
    if not ds.callables and "callables" not in ds.present:
        return
    group = f.create_group("callables")
    for name in sorted(ds.callables):
        obj = ds.callables[name]
        sub = group.create_group(name)
        kind = getattr(obj, "type", "")
        if not kind:
            raise MestraError(
                "E15", "a callable must carry a type string", name)
        write_string_attr(sub, "type", kind)
        line = _repr_line(obj)
        if line is not None:
            write_string_attr(sub, "repr", line)
        encode_dict(sub, obj.to_dict())


def _repr_line(obj: Any) -> str | None:
    """The optional one-line description of section 10."""
    if type(obj).__repr__ is object.__repr__:
        return None
    line = repr(obj)
    return line if "\n" not in line else None


