"""The validator of SPEC.md section 14.

`validate(path)` opens a file and reports every rule it breaks, by
identifier. `validate(dataset)` checks what an in-memory dataset can
be checked for, which is everything except the byte-level rules of
sections 18 to 25.

Identifiers are stable: within a major version a rule is never
renumbered and a retired rule's identifier is never reused. E07 and
W09 were retired on 2026-09-20 and this validator never emits them.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

import h5py
import numpy as np

from .encoding import (
    NULL_SENTINEL,
    default_chunk_rows,
    is_fixed_string,
    read_attr,
    scale_names,
    string_length,
    support_digest,
)
from .errors import Finding
from .model import ARRAY_ROLES, KEY_ROLES, STATISTICS, Dataset
from .names import MACHINERY, RESERVED_PREFIX, is_legal_name
from .units import is_parseable

__all__ = ["Report", "validate"]

#: Section 20: the allowed cell type codes and the nodes each takes.
CELL_TYPES: dict[int, int] = {
    1: 1, 3: 2, 5: 3, 7: -1, 9: 4, 10: 4, 12: 8, 13: 6, 14: 5,
    21: 3, 22: 6, 23: 8, 24: 10, 25: 20, 26: 15, 27: 13,
}

_ROOT_ATTRS = ("format", "writer", "created", "aligned",
               "generalisation_group")
_ROOT_GROUPS = ("keys", "scalars", "categories", "supports",
                "callables", "notes", "private")
_KEY_ATTRS = ("role", "units", "lower", "upper", "category",
              "trajectory_group", "parent")
_SCALAR_ATTRS = ("units", "source", "output", "statistic", "of",
                 "quantile")
_ARRAY_ATTRS = ("role", "varies", "units", "components", "source",
                "output", "statistic", "of", "quantile", "category",
                "recomputed", "derived_from", "recipe", "reference")
_SUPPORT_ATTRS = ("kind", "n_nodes", "n_cells", "support_id")
_SUPPORT_MEMBERS = ("node", "cell", "cell_plus_one", "index", "row",
                    "cell_types", "cell_offsets", "cell_connectivity",
                    "coordinates", "node_arrays", "cell_arrays")

#: Attributes whose encoding section 18 fixes, by the kind it fixes.
_ATTR_KIND = {
    "format": "string", "writer": "string", "created": "string",
    "generalisation_group": "string", "role": "string",
    "units": "string", "category": "string", "source": "string",
    "output": "string", "statistic": "string", "of": "string",
    "varies": "string", "kind": "string", "support_id": "string",
    "derived_from": "string", "recipe": "string", "reference": "string",
    "trajectory_group": "string", "parent": "string", "type": "string",
    "repr": "string",
    "n_nodes": "integer", "n_cells": "integer", "components": "integer",
    "lower": "float", "upper": "float", "quantile": "float",
    "aligned": "boolean", "recomputed": "boolean",
}

#: The findings that say public information is missing, which is what
#: a validator can see of E18.
_MISSING_PUBLIC = ("E02", "E11", "E13", "E15", "E17", "E31", "E39")

#: W08: bounds wider than the observed range by more than this.
_STALE_BOUNDS_FACTOR = 4.0


@dataclass
class Report:
    """What the validator found, by rule identifier."""

    errors: list[Finding] = field(default_factory=list)
    warnings: list[Finding] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True when the file is accepted: no error."""
        return not self.errors

    @property
    def error_ids(self) -> list[str]:
        """The error identifiers, sorted and without duplicates."""
        return sorted({f.rule for f in self.errors})

    @property
    def warning_ids(self) -> list[str]:
        """The warning identifiers, sorted and without duplicates."""
        return sorted({f.rule for f in self.warnings})

    def __str__(self) -> str:
        lines = [str(f) for f in self.errors]
        lines += [str(f) for f in self.warnings]
        if not lines:
            return "no error and no warning"
        return "\n".join(lines)


def validate(target: Any) -> Report:
    """Validate a file by path, or a dataset already in memory."""
    if isinstance(target, Dataset):
        return _validate_dataset(target)
    with h5py.File(str(target), "r") as f:
        return _FileValidator(f).run()


# --------------------------------------------------------------- a file

class _FileValidator:
    """Every rule of section 14 that a file can break."""

    def __init__(self, f: h5py.File) -> None:
        self.f = f
        self.report = Report()
        self.n_rows = 0
        self.support_names: list[str] = []
        self.rows_on: dict[str, np.ndarray] = {}
        self.row_support: np.ndarray | None = None
        self.categories: dict[str, list[str]] = {}
        self.keys: dict[str, h5py.Dataset] = {}
        self.group_keys: list[str] = []

    # -- collecting findings

    def error(self, rule: str, where: str, message: str) -> None:
        self.report.errors.append(Finding(rule, where, message))

    def warn(self, rule: str, where: str, message: str) -> None:
        self.report.warnings.append(Finding(rule, where, message))

    def run(self) -> Report:
        if not self._version():
            return self.report
        self._collect()
        self._root()
        self._categories()
        self._keys()
        self._scalars()
        self._supports()
        self._alignment()
        self._callables()
        self._bytes()
        self._private()
        return self.report

    # -- section 28: the version decides whether to read at all

    def _version(self) -> bool:
        if "format" not in self.f.attrs:
            self.error("E01", "/", "the root attribute format is "
                                   "missing")
            self.error("E17", "/", "format is required")
            return False
        text = read_attr(self.f, "format")
        major = None
        if isinstance(text, str) and text.startswith("mestra/"):
            tail = text[len("mestra/"):]
            major = int(tail) if tail.isdigit() else None
        if major != 0:
            self.error("E01", "/", "this reader accepts mestra/0 and "
                                   "the file says %r" % (text,))
            return False
        return True

    # -- what the rest of the checks need

    def _collect(self) -> None:
        if "row" in self.f and isinstance(self.f["row"], h5py.Dataset):
            self.n_rows = int(self.f["row"].shape[0])
        if "categories" in self.f:
            for name, dset in self.f["categories"].items():
                if isinstance(dset, h5py.Dataset):
                    self.categories[name] = _strings(dset)
        if "keys" in self.f:
            for name, dset in self.f["keys"].items():
                if isinstance(dset, h5py.Dataset):
                    self.keys[name] = dset
                    if _attr(dset, "role") == "group":
                        self.group_keys.append(name)
        if "supports" in self.f:
            self.support_names = sorted(
                (n for n, m in self.f["supports"].items()
                 if isinstance(m, h5py.Group)),
                key=lambda n: n.encode("utf-8"))
        if ("row_support" in self.f
                and isinstance(self.f["row_support"], h5py.Dataset)):
            self.row_support = np.asarray(self.f["row_support"][()])
        for at, name in enumerate(self.support_names):
            if self.row_support is None:
                self.rows_on[name] = np.arange(self.n_rows)
            else:
                self.rows_on[name] = np.flatnonzero(
                    self.row_support == at)

    # -- the root group

    def _root(self) -> None:
        attrs = _names(self.f)
        for name in ("format", "writer", "created"):
            if name not in attrs:
                self.error("E17", "/", "the root attribute %s is "
                                       "missing" % name)
        if "aligned" not in attrs:
            self.error("E39", "/", "the root attribute aligned is "
                                   "required")
        if self.group_keys and "generalisation_group" not in attrs:
            self.error(
                "E39", "/", "a file that declares a group key names "
                "the unit of generalisation in the root attribute "
                "generalisation_group")
        if "created" in attrs and not _is_iso_utc(
                read_attr(self.f, "created")):
            self.warn("W14", "/", "created is not an ISO 8601 UTC "
                                  "timestamp")
        for name in attrs:
            if name not in _ROOT_ATTRS:
                self.warn("W11", "/", "this reader does not know the "
                                      "attribute %s, and ignores it"
                          % name)
        for name, member in self.f.items():
            if name in _ROOT_GROUPS or name == "row_support":
                continue
            if isinstance(member, h5py.Dataset):
                continue                    # a dimension scale at root
            self.warn("W11", "/" + name, "this reader does not know "
                                         "this group, and ignores it")

    def _private(self) -> None:
        """E18, from the public objects a validator can see missing.

        Section 29 forbids a validator to interpret /private, so all
        it can say is that public information is missing from a file
        that carries one.
        """
        if "private" not in self.f:
            return
        missing = [f for f in self.report.errors
                   if f.rule in _MISSING_PUBLIC]
        if missing:
            self.error(
                "E18", "/private", "public information is missing "
                "from this file (%s) and the file carries a private "
                "group; a writer must not put public information only "
                "there" % ", ".join(sorted({f.rule for f in missing})))

    # -- category tables

    def _categories(self) -> None:
        if "categories" not in self.f:
            return
        for name, dset in self.f["categories"].items():
            where = "/categories/" + name
            if not isinstance(dset, h5py.Dataset):
                continue
            if not is_fixed_string(dset.dtype):
                self.error("E20", where, "a category table is a "
                                         "fixed-length UTF-8 string "
                                         "dataset")
                continue
            self._strings_of(dset, where, "E26")

    def _strings_of(self, dset: h5py.Dataset, where: str,
                    rule: str) -> None:
        """E26: valid UTF-8, and no NUL outside the padding."""
        size = string_length(dset.dtype) or 1
        longest = 0
        for raw in np.asarray(dset[()]).reshape(-1):
            if not isinstance(raw, bytes):
                continue
            body = raw.rstrip(b"\x00")
            longest = max(longest, len(body))
            if b"\x00" in body:
                self.error(rule, where, "a fixed-length string holds a "
                                        "NUL byte outside its trailing "
                                        "padding")
            try:
                body.decode("utf-8")
            except UnicodeDecodeError:
                self.error(rule, where, "a fixed-length string is not "
                                        "valid UTF-8")
        if size > max(1, longest):
            self.warn("W13", where, "this string dataset is %d bytes "
                                    "wide where %d would do"
                      % (size, max(1, longest)))

    # -- keys

    def _keys(self) -> None:
        roles: dict[str, list[str]] = {}
        for name in sorted(self.keys):
            dset = self.keys[name]
            where = "/keys/" + name
            self._name(name, where)
            attrs = _names(dset)
            role = _attr(dset, "role")
            if role is None:
                self.error("E02", where, "a key carries a role")
            elif role not in KEY_ROLES:
                self.error("E02", where, "%r is not a key role of "
                                         "section 3" % role)
            else:
                roles.setdefault(role, []).append(name)
            self._unknown_attrs(dset, where, _KEY_ATTRS)
            self._units(dset, where)
            if (role in ("design", "condition", "time")
                    and "units" not in attrs):
                self.error("E39", where, "a %s key carries units"
                           % role)
            if (role in ("categorical", "group", "split", "status")
                    and "category" not in attrs):
                self.error("E39", where, "a %s key names its category "
                                         "table" % role)
            if (role == "time" and self.group_keys
                    and "trajectory_group" not in attrs):
                self.error("E39", where, "the time key names its "
                                         "trajectory_group")
            self._key_dtype(dset, where, role)
            self._rows(dset, where, self.n_rows)
            self._categories_of(dset, where, role)
            self._bounds(dset, where, role)
        self._cardinality(roles)
        self._time(roles)
        self._status(roles)
        self._split(roles)

    def _key_dtype(self, dset: h5py.Dataset, where: str,
                   role: str | None) -> None:
        dtype = dset.dtype
        if role in ("design", "condition", "time"):
            _ = self._float64(dset, where, "a %s key" % role)
        elif role in ("categorical", "group", "split", "status"):
            if dtype.kind not in "iu" or dtype.itemsize not in (4, 8):
                self.error("E20", where, "a %s key is int32 or int64, "
                                         "and this is %s"
                           % (role, dtype))
        elif role == "id" and not is_fixed_string(dtype) and not (
                dtype.kind == "i" and dtype.itemsize == 8):
            self.error("E20", where, "an id key is int64 or a "
                                     "fixed-length UTF-8 string")

    def _categories_of(self, dset: h5py.Dataset, where: str,
                       role: str | None) -> None:
        """E10 and W07: values against the category table."""
        if role not in ("categorical", "group", "split", "status"):
            return
        table_name = _attr(dset, "category")
        if table_name is None:
            return
        table = self.categories.get(table_name)
        if table is None:
            self.error("E10", where, "there is no category table "
                                     "called %r" % table_name)
            return
        values = np.asarray(dset[()])
        if values.size and values.dtype.kind in "iu":
            outside = values[(values < 0) | (values >= len(table))]
            if outside.size:
                self.error("E10", where, "the value %d is outside a "
                                         "category table of %d entries"
                           % (int(outside[0]), len(table)))
        if role == "group":
            used = {int(v) for v in np.asarray(values).reshape(-1)}
            unused = [t for at, t in enumerate(table) if at not in used]
            if unused:
                self.warn("W07", where, "the category table has an "
                                        "entry no row uses: %s"
                          % ", ".join(unused))

    def _bounds(self, dset: h5py.Dataset, where: str,
                role: str | None) -> None:
        """W04 and W08: the declared bounds against the values."""
        attrs = _names(dset)
        lower = read_attr(dset, "lower") if "lower" in attrs else None
        upper = read_attr(dset, "upper") if "upper" in attrs else None
        if lower is None and upper is None:
            return
        values = np.asarray(dset[()])
        if values.dtype.kind not in "fiu" or not values.size:
            return
        finite = values[np.isfinite(values)] if values.dtype.kind == "f" \
            else values
        if not finite.size:
            return
        low, high = float(np.min(finite)), float(np.max(finite))
        outside = ((lower is not None and low < lower)
                   or (upper is not None and high > upper))
        if outside:
            self.warn("W04", where, "a value is outside the declared "
                                    "bounds [%s, %s]" % (lower, upper))
            return
        if lower is None or upper is None:
            return
        observed = high - low
        declared = float(upper) - float(lower)
        if observed > 0 and declared > _STALE_BOUNDS_FACTOR * observed:
            self.warn("W08", where, "the declared bounds are %.1f "
                                    "times wider than the observed "
                                    "range, which is what stale bounds "
                                    "look like" % (declared / observed))

    def _cardinality(self, roles: dict[str, list[str]]) -> None:
        """E03: a role's cardinality violated."""
        for role, limit in KEY_ROLES.items():
            if limit is None:
                continue
            found = roles.get(role, [])
            if len(found) > limit:
                self.error("E03", "/keys", "a file has at most %d key "
                                           "with the role %s, and this "
                                           "one has %d: %s"
                           % (limit, role, len(found),
                              ", ".join(found)))

    def _time(self, roles: dict[str, list[str]]) -> None:
        """E09: time strictly increasing within each trajectory."""
        for name in roles.get("time", []):
            dset = self.keys[name]
            values = np.asarray(dset[()])
            group = _attr(dset, "trajectory_group")
            if group and group in self.keys:
                labels = np.asarray(self.keys[group][()])
            else:
                labels = np.zeros(len(values), dtype="i8")
            if len(labels) != len(values):
                continue
            for one in np.unique(labels):
                inside = values[labels == one]
                if inside.size > 1 and not np.all(
                        np.diff(inside) > 0):
                    self.error(
                        "E09", "/keys/" + name, "time is not strictly "
                        "increasing within the trajectory %s" % one)

    def _status(self, roles: dict[str, list[str]]) -> None:
        """W02: rows whose status is not converged."""
        for name in roles.get("status", []):
            dset = self.keys[name]
            table = self.categories.get(_attr(dset, "category") or "")
            if not table:
                continue
            values = np.asarray(dset[()])
            for row, value in enumerate(values):
                at = int(value)
                if 0 <= at < len(table) and table[at] != "converged":
                    self.warn(
                        "W02", "/keys/" + name, "row %d has status %r"
                        % (row, table[at]))

    def _split(self, roles: dict[str, list[str]]) -> None:
        """W01: a split that leaks the unit of generalisation."""
        if "generalisation_group" not in _names(self.f):
            return
        unit = read_attr(self.f, "generalisation_group")
        if unit not in self.keys:
            return
        units = np.asarray(self.keys[unit][()])
        for name in roles.get("split", []):
            split = np.asarray(self.keys[name][()])
            if len(split) != len(units):
                continue
            for one in np.unique(units):
                if len(np.unique(split[units == one])) > 1:
                    self.warn(
                        "W01", "/keys/" + name, "the rows of %s %s are "
                        "on both sides of the split, so this is not a "
                        "generalisation test" % (unit, one))

    # -- scalars

    def _scalars(self) -> None:
        if "scalars" not in self.f:
            return
        for name, member in self.f["scalars"].items():
            where = "/scalars/" + name
            self._name(name, where)
            self._unknown_attrs(member, where, _SCALAR_ATTRS)
            attrs = _names(member)
            if "units" not in attrs:
                self.error("E11", where, "a scalar carries units")
            self._units(member, where)
            self._source(member, where)
            self._statistic(member, where)
            if isinstance(member, h5py.Dataset):
                self._float64(member, where, "a scalar")
                self._rows(member, where, self.n_rows)
                self._finite(member, where)
            elif "components" in attrs:
                self.warn("W11", where, "components is not used on a "
                                        "scalar")

    # -- supports

    def _supports(self) -> None:
        if "supports" not in self.f:
            return
        for name in self.support_names:
            self._support(name, self.f["supports"][name])

    def _support(self, name: str, group: h5py.Group) -> None:
        where = "/supports/" + name
        self._name(name, where)
        self._unknown_attrs(group, where, _SUPPORT_ATTRS)
        attrs = _names(group)
        for required in _SUPPORT_ATTRS:
            if required not in attrs:
                self.error("E39", where, "a support carries %s"
                           % required)
        kind = _attr(group, "kind") or "mesh"
        n_nodes = _attr(group, "n_nodes") or 0
        cells = {which: group[which]
                 for which in ("cell_types", "cell_offsets",
                               "cell_connectivity")
                 if which in group}
        if kind == "mesh" and len(cells) != 3:
            self.error("E38", where, "a mesh support carries "
                                     "cell_types, cell_offsets and "
                                     "cell_connectivity")
        if kind in ("axis", "none") and (cells or "cell" in group):
            self.error("E38", where, "a support of kind %s carries no "
                                     "cell datasets and no cell "
                                     "dimension" % kind)
        self._cells(where, cells, int(n_nodes))
        self._support_id(where, group, kind, int(n_nodes), cells)

        arrays = []
        if "coordinates" in group:
            arrays.append(("coordinates", group["coordinates"], "node"))
        for which, location in (("node_arrays", "node"),
                                ("cell_arrays", "cell")):
            if which in group:
                for slot_name, member in group[which].items():
                    arrays.append(("%s/%s" % (which, slot_name), member,
                                   location))
        if kind in ("mesh", "axis") and "coordinates" not in group:
            self.error("E03", where, "a %s support has exactly one "
                                     "coordinates array" % kind)
        roles: dict[str, list[str]] = {}
        for slot_name, member, location in arrays:
            role = self._array(where, name, slot_name, member, location,
                               kind, int(n_nodes),
                               int(_attr(group, "n_cells") or 0))
            if role is not None:
                roles.setdefault(
                    role if role != "coordinates" else "coordinates",
                    []).append(slot_name)
        for role, limit in ARRAY_ROLES.items():
            if limit is not None and len(roles.get(role, [])) > limit:
                self.error("E03", where, "a support has at most %d "
                                         "array with the role %s"
                           % (limit, role))
        for member_name, member in group.items():
            if member_name in _SUPPORT_MEMBERS:
                continue
            if isinstance(member, h5py.Group):
                self.warn("W11", "%s/%s" % (where, member_name),
                          "this reader does not know this group, and "
                          "ignores it")

    def _cells(self, where: str, cells: dict[str, h5py.Dataset],
               n_nodes: int) -> None:
        """E21 to E24: the cell arrays against section 20."""
        if len(cells) != 3:
            return
        types = np.asarray(cells["cell_types"][()])
        offsets = np.asarray(cells["cell_offsets"][()])
        connectivity = np.asarray(cells["cell_connectivity"][()])
        if cells["cell_types"].dtype != np.dtype("u1"):
            self.error("E20", where + "/cell_types", "cell_types is "
                                                     "uint8")
        for which in ("cell_offsets", "cell_connectivity"):
            if cells[which].dtype != np.dtype("<i8"):
                self.error("E20", where + "/" + which,
                           "%s is little-endian int64" % which)
        for code in np.unique(types):
            if int(code) not in CELL_TYPES:
                self.error("E21", where + "/cell_types", "%d is not a "
                                                         "cell type "
                                                         "code of "
                                                         "section 20"
                           % int(code))
        bad_offsets = (len(offsets) != len(types) + 1
                       or (offsets.size and offsets[0] != 0)
                       or np.any(np.diff(offsets) < 0)
                       or (offsets.size
                           and offsets[-1] != len(connectivity)))
        if bad_offsets:
            self.error("E23", where + "/cell_offsets",
                       "cell_offsets starts at 0, does not decrease, "
                       "and ends at the length of cell_connectivity")
        else:
            for at, code in enumerate(types):
                width = int(offsets[at + 1] - offsets[at])
                wanted = CELL_TYPES.get(int(code))
                if wanted is None:
                    continue
                if wanted == -1:
                    if width < 3:
                        self.error("E22", where, "cell %d is a polygon "
                                                 "of %d nodes"
                                   % (at, width))
                elif width != wanted:
                    self.error("E22", where, "cell %d is type %d and "
                                             "takes %d nodes, and the "
                                             "offsets give it %d"
                               % (at, int(code), wanted, width))
        if connectivity.size:
            outside = connectivity[(connectivity < 0)
                                   | (connectivity >= n_nodes)]
            if outside.size:
                self.error("E24", where + "/cell_connectivity",
                           "the value %d is outside [0, %d)"
                           % (int(outside[0]), n_nodes))

    def _support_id(self, where: str, group: h5py.Group, kind: str,
                    n_nodes: int, cells: dict[str, Any]) -> None:
        """E08: the digest against the stored arrays (section 24)."""
        if "support_id" not in _names(group):
            return
        axis_coordinates = None
        if kind == "axis" and "coordinates" in group:
            # Section 24, decision 27: the digest of an axis support
            # is over the coordinates as they are stored, so that a
            # file whose axis coordinates wrongly vary breaks E35 and
            # nothing else.
            axis_coordinates = np.asarray(group["coordinates"][()])
        if kind != "mesh":
            # A support of kind axis or none has no cell arrays, so
            # steps 2 to 4 contribute no bytes at all for it.
            cells = {}
        digest = support_digest(
            n_nodes,
            cells["cell_types"][()] if "cell_types" in cells else None,
            cells["cell_offsets"][()] if "cell_offsets" in cells
            else None,
            cells["cell_connectivity"][()]
            if "cell_connectivity" in cells else None,
            axis_coordinates)
        stored = _attr(group, "support_id")
        if stored != digest:
            self.error("E08", where, "the stored support_id does not "
                                     "match the arrays; they hash to "
                                     "%s" % digest)

    def _array(self, support_where: str, support_name: str, name: str,
               member: Any, location: str, kind: str, n_nodes: int,
               n_cells: int) -> str | None:
        where = "%s/%s" % (support_where, name)
        self._name(name.rsplit("/", 1)[-1], where)
        self._unknown_attrs(member, where, _ARRAY_ATTRS)
        attrs = _names(member)
        role = _attr(member, "role")
        if role is None:
            self.error("E02", where, "an array carries a role")
        elif role not in ARRAY_ROLES:
            self.error("E02", where, "%r is not an array role of "
                                     "section 3" % role)
        varies = _attr(member, "varies")
        if varies is None:
            self.error("E39", where, "an array carries varies")
            varies = "none"
        if role == "field" and "units" not in attrs:
            self.error("E11", where, "a field carries units")
        if role in ("coordinates", "derived") and "units" not in attrs:
            self.error("E39", where, "a %s array carries units" % role)
        self._units(member, where)
        self._source(member, where)
        self._statistic(member, where)
        if role == "derived" and ("derived_from" not in attrs
                                  or "recipe" not in attrs):
            self.error("E13", where, "a derived array carries "
                                     "derived_from and recipe")
        if role in ("weight", "normal") and "recomputed" not in attrs:
            self.warn("W06", where, "%s arrays are recomputed from the "
                                    "connectivity, never imported; say "
                                    "so with recomputed" % role)
        if name == "coordinates" and kind == "axis" and varies != "none":
            self.error("E35", where, "the coordinates of an axis "
                                     "support are part of its identity "
                                     "and have varies = none")
        components = _attr(member, "components")
        if components is None:
            self.error("E31", where, "an array slot declares its "
                                     "components")

        if not isinstance(member, h5py.Dataset):
            return role
        self._array_dtype(member, where, role)
        dims = _logical(member)
        wanted = 1 + (1 if varies != "none" else 0) \
            + (1 if _attr(member, "statistic") == "draw" else 0) + 1
        if member.ndim != wanted:
            self.error("E04", where, "an array with varies = %s has %d "
                                     "axes, and this one has %d"
                       % (varies, wanted, member.ndim))
        elif varies != "none":
            leading = dims[0] if dims else ""
            if varies == "row" and leading != "row":
                self.error("E04", where, "varies = row, and the "
                                         "leading dimension is %s"
                           % leading)
            if varies.startswith("group:") and leading != varies:
                self.error("E04", where, "varies = %s, and the leading "
                                         "dimension is %s"
                           % (varies, leading))
        width = n_nodes if location == "node" else n_cells
        at = member.ndim - 2
        if at >= 0 and member.shape[at] != width:
            self.error("E05", where, "this support has %d %ss and the "
                                     "array has %d"
                       % (width, location, member.shape[at]))
        if (components is not None and member.ndim
                and member.shape[-1] != int(components)):
            self.error("E31", where, "components is %d and the "
                                     "component dimension is %d long"
                       % (int(components), member.shape[-1]))
        if varies == "row":
            rows = self.rows_on.get(support_name,
                                    np.arange(self.n_rows))
            self._rows(member, where, len(rows))
        if varies.startswith("group:"):
            key = varies[len("group:"):]
            table = None
            if key in self.keys:
                table = self.categories.get(
                    _attr(self.keys[key], "category") or "")
            if table is not None and member.ndim and \
                    member.shape[0] != len(table):
                self.error("E34", where, "the group key %s has %d "
                                         "categories and this array "
                                         "has %d instances"
                           % (key, len(table), member.shape[0]))
        if role == "label":
            self._label(member, where)
        if role in ("field", "derived"):
            self._finite(member, where)
        return role

    def _array_dtype(self, dset: h5py.Dataset, where: str,
                     role: str | None) -> None:
        if role == "label":
            if dset.dtype.kind not in "iu" or \
                    dset.dtype.itemsize not in (4, 8):
                self.error("E20", where, "a label is int32 or int64, "
                                         "and this is %s" % dset.dtype)
            return
        if role in ("coordinates", "field", "derived", "weight",
                    "normal"):
            self._float64(dset, where, "a %s array" % role)

    def _label(self, dset: h5py.Dataset, where: str) -> None:
        """E10: a label whose table does not hold one of its values."""
        table_name = _attr(dset, "category")
        if table_name is None:
            return                  # its values are its own categories
        table = self.categories.get(table_name)
        if table is None:
            self.error("E10", where, "there is no category table "
                                     "called %r" % table_name)
            return
        values = np.asarray(dset[()])
        if values.size and values.dtype.kind in "iu":
            outside = values[(values < 0) | (values >= len(table))]
            if outside.size:
                self.error("E10", where, "the value %d is outside a "
                                         "category table of %d entries"
                           % (int(outside[0]), len(table)))

    # -- alignment

    def _alignment(self) -> None:
        """E06, E28, E37, W05 and W15 (sections 8 and 22)."""
        count = len(self.support_names)
        aligned = None
        if "aligned" in _names(self.f):
            aligned = bool(read_attr(self.f, "aligned"))
        has_column = self.row_support is not None
        if aligned is not None:
            if aligned and count > 1:
                self.error("E37", "/", "aligned is true and the file "
                                       "declares %d supports" % count)
            if not aligned and count <= 1:
                self.error("E37", "/", "aligned is false and the file "
                                       "declares %d support" % count)
            if aligned and has_column:
                self.error("E28", "/row_support", "an aligned file "
                                                  "carries no "
                                                  "/row_support")
            if not aligned and not has_column:
                self.error("E28", "/", "an unaligned file carries a "
                                       "/row_support for every row")
        if count > 1:
            self.warn("W05", "/supports", "the file declares %d "
                                          "supports, so index-aligned "
                                          "operations are not "
                                          "available" % count)
        if has_column:
            values = np.asarray(self.row_support)
            if self.f["row_support"].dtype != np.dtype("<i4"):
                self.error("E20", "/row_support", "/row_support is "
                                                  "little-endian int32")
            self._rows(self.f["row_support"], "/row_support",
                       self.n_rows)
            outside = values[(values < 0) | (values >= max(count, 1))]
            if outside.size:
                self.error("E06", "/row_support", "a row references "
                                                  "support %d, and the "
                                                  "file declares %d"
                           % (int(outside[0]), count))
            for at, name in enumerate(self.support_names):
                if not np.any(values == at):
                    self.warn("W15", "/supports/" + name, "no row "
                                                          "references "
                                                          "this "
                                                          "support")

    # -- callables

    def _callables(self) -> None:
        if "callables" not in self.f:
            return
        for name, group in self.f["callables"].items():
            where = "/callables/" + name
            self._name(name, where)
            if not isinstance(group, h5py.Group):
                self.error("E15", where, "a callable is a group")
                continue
            if "type" not in _names(group):
                self.error("E15", where, "a callable carries a type "
                                         "string")
            self._dictionary(group, where, top_level=True)

    def _dictionary(self, group: h5py.Group, where: str,
                    top_level: bool) -> None:
        """E32 and E33 over one dictionary group (section 25)."""
        for name, member in group.items():
            if name.startswith(RESERVED_PREFIX):
                continue
            path = "%s/%s" % (where, name)
            if top_level and name in ("type", "repr"):
                self.error("E32", path, "type and repr are the "
                                        "container's attributes, so a "
                                        "dictionary may not use them "
                                        "at its top level")
            if not is_legal_name(name):
                self.error("E33", path, "a dictionary key is a legal "
                                        "netCDF-4 name")
            if isinstance(member, h5py.Group):
                self._dictionary(member, path, top_level=False)
                continue
            if member.attrs.get("CLASS", b"") == b"DIMENSION_SCALE":
                continue
            if member.ndim == 0:
                self.error("E32", path, "a zero-dimensional array is "
                                        "written as an attribute, not "
                                        "as a dataset")
                continue
            if is_fixed_string(member.dtype):
                self._strings_of(member, path, "E32")
                continue
            if member.dtype.name not in ("int8", "int32", "int64",
                                         "float64"):
                self.error("E32", path, "%s is not a dtype a dictionary "
                                        "may hold" % member.dtype)
        for name in _names(group):
            if name.startswith(RESERVED_PREFIX):
                continue
            if top_level and name in ("type", "repr"):
                continue
            if not is_legal_name(name):
                self.error("E33", "%s/%s" % (where, name), "a "
                           "dictionary key is a legal netCDF-4 name")

    # -- the byte-level sweep

    def _bytes(self) -> None:
        """E19, E25, E26, E27, E29, E33 and W12 over every object.

        /private is left alone, because section 12 lets a producer
        keep its own records there in whatever representation it
        chooses and section 29 forbids a reader to interpret them.
        A group this version does not know is left alone too:
        section 28 says to ignore it and report it, which is the W11
        the root check already made.
        """
        self._object(self.f, "/")
        stack = [(self.f, "")]
        while stack:
            group, prefix = stack.pop()
            for name, member in group.items():
                path = "%s/%s" % (prefix, name)
                if not prefix and name not in _ROOT_GROUPS \
                        and name != "row_support" \
                        and isinstance(member, h5py.Group):
                    continue
                if path == "/private":
                    continue
                self._object(member, path)
                if isinstance(member, h5py.Group):
                    stack.append((member, path))
                else:
                    self._dataset(member, path)

    def _object(self, obj: Any, path: str) -> None:
        for name in obj.attrs:
            if name in MACHINERY:
                continue
            if not is_legal_name(name):
                self.error("E33", path, "the attribute name %r is not "
                                        "a legal netCDF-4 name" % name)
            self._attr_encoding(obj, name, path)

    def _attr_encoding(self, obj: Any, name: str, path: str) -> None:
        """E19: the encoding section 18 requires (section 18)."""
        attr = obj.attrs.get_id(name)
        kind = _ATTR_KIND.get(name)
        htype = attr.get_type()
        if isinstance(htype, h5py.h5t.TypeStringID):
            if htype.is_variable_str():
                self.error("E19", path, "the attribute %s is a "
                                        "variable-length string, which "
                                        "section 18 forbids anywhere"
                           % name)
                return
            if htype.get_cset() != h5py.h5t.CSET_UTF8:
                self.error("E19", path, "the attribute %s is a string "
                                        "that is not UTF-8" % name)
            if htype.get_strpad() != h5py.h5t.STR_NULLPAD:
                self.error("E19", path, "the attribute %s is a string "
                                        "that is not NUL padded" % name)
            if kind is not None and kind != "string":
                self.error("E19", path, "the attribute %s is a %s and "
                                        "is stored as a string"
                           % (name, kind))
            raw = obj.attrs[name]
            if (isinstance(raw, bytes) and raw != NULL_SENTINEL
                    and b"\x00" in raw.rstrip(b"\x00")):
                self.error("E26", path, "the attribute %s holds a NUL "
                                        "byte outside its trailing "
                                        "padding" % name)
            return
        dtype = attr.dtype
        if kind == "string":
            self.error("E19", path, "the attribute %s is a string and "
                                    "is stored as %s" % (name, dtype))
            return
        if kind == "boolean" or (kind is None and dtype == np.int8):
            if dtype != np.int8:
                self.error("E19", path, "the boolean attribute %s is "
                                        "int8, and this is %s"
                           % (name, dtype))
            elif int(np.asarray(obj.attrs[name]).reshape(-1)[0]) \
                    not in (0, 1):
                self.error("E19", path, "the boolean attribute %s is 0 "
                                        "or 1" % name)
            return
        if kind == "integer":
            if dtype != np.dtype("int64"):
                self.error("E19", path, "the integer attribute %s is "
                                        "int64, and this is %s"
                           % (name, dtype))
            return
        if kind == "float":
            if dtype != np.dtype("float64"):
                self.error("E19", path, "the float attribute %s is "
                                        "float64, and this is %s"
                           % (name, dtype))
            elif not np.isfinite(np.asarray(obj.attrs[name])).all():
                self.error("E19", path, "the attribute %s declares a "
                                        "bound or a quantile and must "
                                        "be finite" % name)
            return
        if dtype not in (np.dtype("int64"), np.dtype("float64"),
                         np.dtype("int8")):
            self.error("E19", path, "the attribute %s is %s; section "
                                    "18 has int8, int64, float64 and "
                                    "fixed-length strings"
                       % (name, dtype))

    def _dataset(self, dset: h5py.Dataset, path: str) -> None:
        if dset.attrs.get("CLASS", b"") == b"DIMENSION_SCALE":
            if (path.rsplit("/", 1)[-1] == "row"
                    and dset.maxshape[0] is not None):
                self.error("E27", path, "row is an unlimited dimension "
                                        "in every file")
            return
        for axis, names in enumerate(scale_names(dset)):
            if len(names) != 1:
                self.error("E25", path, "axis %d carries %d dimension "
                                        "scales, and every axis "
                                        "carries exactly one"
                           % (axis, len(names)))
        self._scale_names(dset, path)
        if dset.fletcher32:
            self.error("E29", path, "fletcher32 is not one of the two "
                                    "portable filters")
        if dset.compression not in (None, "gzip"):
            self.error("E29", path, "%s is not one of the two portable "
                                    "filters" % dset.compression)
        if dset.compression == "gzip" and \
                not 1 <= int(dset.compression_opts or 0) <= 9:
            self.error("E29", path, "gzip is allowed at levels 1 to 9")
        dims = _logical(dset)
        if dims[:1] == ("row",):
            if dset.chunks is None:
                self.error("E27", path, "a row-dimensioned dataset is "
                                        "chunked, because row is "
                                        "unlimited")
            else:
                self._chunk(dset, path)

    def _scale_names(self, dset: h5py.Dataset, path: str) -> None:
        """E25: the name section 21 requires for each axis."""
        wanted = _wanted_dims(path, dset)
        if wanted is None:
            return
        got = [names[0] if len(names) == 1 else None
               for names in scale_names(dset)]
        for axis, (have, allowed) in enumerate(zip(got, wanted)):
            if have is None or allowed is None:
                continue
            if not allowed(have, dset.shape[axis]):
                self.error("E25", path, "axis %d carries the dimension "
                                        "%s, which is not the name "
                                        "section 21 requires"
                           % (axis, have))

    def _chunk(self, dset: h5py.Dataset, path: str) -> None:
        """W12: a chunk shape that is not the default of section 23."""
        rows = _row_length(dset)
        default = (default_chunk_rows(dset.dtype.itemsize,
                                      dset.shape[1:], rows),) \
            + tuple(dset.shape[1:])
        if tuple(dset.chunks) != default:
            self.warn("W12", path, "the chunk is %s where the default "
                                   "of section 23 is %s"
                      % (tuple(dset.chunks), default))

    # -- small shared checks

    def _name(self, name: str, where: str) -> None:
        """E33: a producer-chosen name."""
        if not is_legal_name(name):
            self.error("E33", where, "%r is not a legal netCDF-4 name"
                       % name)
        elif name.startswith(RESERVED_PREFIX):
            self.error("E33", where, "%s is reserved for the container "
                                     "everywhere in the file"
                       % RESERVED_PREFIX)

    def _unknown_attrs(self, obj: Any, where: str,
                       known: Sequence[str]) -> None:
        """W11: an attribute this reader does not know."""
        for name in _names(obj):
            if name not in known:
                self.warn("W11", where, "this reader does not know the "
                                        "attribute %s, and ignores it"
                          % name)

    def _units(self, obj: Any, where: str) -> None:
        """W10: a units string the validator cannot parse."""
        if "units" not in _names(obj):
            return
        text = read_attr(obj, "units")
        if isinstance(text, str) and not is_parseable(text):
            self.warn("W10", where, "the units string %r does not parse"
                      % text)

    def _source(self, obj: Any, where: str) -> None:
        """E14, E30, E36 and E39 over one slot's source."""
        attrs = _names(obj)
        if "source" not in attrs:
            self.error("E39", where, "a slot carries source")
            return
        source = read_attr(obj, "source")
        if source == "data":
            if not isinstance(obj, h5py.Dataset):
                self.error("E30", where, "a slot whose source is data "
                                         "is a dataset, not a group")
            return
        if not isinstance(source, str) or \
                not source.startswith("callable:"):
            self.error("E36", where, "source is data or callable:<id>, "
                                     "and this is %r" % (source,))
            return
        if isinstance(obj, h5py.Dataset):
            self.error("E30", where, "a slot a callable serves is a "
                                     "group, not a dataset")
        identifier = source[len("callable:"):]
        if "callables" not in self.f or identifier not in \
                self.f["callables"]:
            self.error("E14", where, "the file holds no callable "
                                     "called %r" % identifier)
        if "output" not in attrs:
            self.error("E39", where, "a slot a callable serves names "
                                     "which output fills it")

    def _statistic(self, obj: Any, where: str) -> None:
        """E12: statistic, of and quantile together (section 9)."""
        attrs = _names(obj)
        if "statistic" not in attrs:
            return
        statistic = read_attr(obj, "statistic")
        if statistic not in STATISTICS:
            self.error("E02", where, "%r is not a statistic of section "
                                     "9" % statistic)
            return
        if statistic == "quantile" and "quantile" not in attrs:
            self.error("E12", where, "a quantile statistic carries its "
                                     "quantile")
        if statistic not in ("value", "draw") and "of" not in attrs:
            self.error("E12", where, "a %s names the quantity it is a "
                                     "statistic of" % statistic)

    def _float64(self, dset: h5py.Dataset, where: str,
                 what: str) -> bool:
        if dset.dtype != np.dtype("<f8"):
            self.error("E20", where, "%s is little-endian float64, and "
                                     "this is %s" % (what, dset.dtype))
            return False
        return True

    def _rows(self, dset: h5py.Dataset, where: str, rows: int) -> None:
        """E16: the leading dimension against the row count."""
        if dset.ndim and dset.shape[0] != rows:
            self.error("E16", where, "this holds %d rows where the "
                                     "file has %d"
                       % (dset.shape[0], rows))

    def _finite(self, dset: h5py.Dataset, where: str) -> None:
        """W03: non-finite values in a field or a scalar."""
        if dset.dtype.kind != "f" or not dset.size:
            return
        values = np.asarray(dset[()])
        bad = ~np.isfinite(values)
        if bad.any():
            first = tuple(int(i) for i in np.argwhere(bad)[0])
            self.warn("W03", where, "a non-finite value at %s, which "
                                    "is how this format spells missing "
                                    "floating-point data"
                      % (first,))


# -------------------------------------------------------------- helpers

def _names(obj: Any) -> list[str]:
    return [n for n in obj.attrs if n not in MACHINERY]


def _attr(obj: Any, name: str) -> Any:
    if name not in obj.attrs or name in MACHINERY:
        return None
    return read_attr(obj, name)


def _strings(dset: h5py.Dataset) -> list[str]:
    return [v.rstrip(b"\x00").decode("utf-8", errors="replace")
            if isinstance(v, bytes) else str(v) for v in dset[()]]


def _logical(dset: h5py.Dataset) -> tuple[str, ...]:
    """The logical dimension names of a dataset, from its scales."""
    from .names import logical_dimension
    out = []
    for names in scale_names(dset):
        out.append(logical_dimension(names[0]) if len(names) == 1
                   else "")
    return tuple(out)


def _row_length(dset: h5py.Dataset) -> int:
    """The length of the row dimension a dataset is written over.

    In an unaligned file a support-local `row` shadows the file's
    one (section 21), and the chunk default follows the dimension
    the dataset actually uses.
    """
    names = scale_names(dset)
    if names and len(names[0]) == 1:
        scale = dset.dims[0][0]
        return int(scale.shape[0])
    return int(dset.shape[0])


def _exact(name: str) -> Any:
    return lambda have, length: have == name


def _component(have: str, length: int) -> bool:
    return have == "component_%d" % length


def _leading(have: str, length: int) -> bool:
    return (have == "row" or have.startswith("group_")
            or have == "draw_%d" % length)


def _wanted_dims(path: str, dset: h5py.Dataset) -> Any:
    """What each axis of a dataset may be called (section 21)."""
    parts = path.strip("/").split("/")
    if path == "/row_support" or parts[:1] == ["keys"]:
        return [_exact("row")]
    if parts[:1] == ["scalars"]:
        return [_exact("row")]
    if parts[:1] == ["categories"] and len(parts) == 2:
        return [_exact("category_" + parts[1])]
    if parts[:1] == ["callables"]:
        name = parts[-1]
        return [(lambda have, length, at=at, name=name:
                 have == "%s%s_d%d" % (RESERVED_PREFIX, name, at))
                for at in range(dset.ndim)]
    if parts[:1] != ["supports"] or len(parts) < 3:
        return None
    last = parts[-1]
    if last == "cell_types":
        return [_exact("cell")]
    if last == "cell_offsets":
        return [_exact("cell_plus_one")]
    if last == "cell_connectivity":
        return [_exact("index")]
    location = "cell" if "cell_arrays" in parts else "node"
    if dset.ndim < 2:
        return None
    return ([_leading] * (dset.ndim - 2)
            + [_exact(location), _component])


def _is_iso_utc(text: Any) -> bool:
    """W14: an ISO 8601 timestamp in UTC (section 11)."""
    if not isinstance(text, str):
        return False
    body = text.strip()
    if body.endswith("Z"):
        body = body[:-1]
    elif body.endswith("+00:00"):
        body = body[:-len("+00:00")]
    else:
        return False
    import datetime
    for form in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f",
                 "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            datetime.datetime.strptime(body, form)
            return True
        except ValueError:
            continue
    return False


# ------------------------------------------------------- a dataset only

def _validate_dataset(ds: Dataset) -> Report:
    """The rules an in-memory dataset can break.

    The byte-level rules of sections 18 to 25 are about a file and
    are not checked here; validate the file itself for those.
    """
    report = Report()

    def error(rule: str, where: str, message: str) -> None:
        report.errors.append(Finding(rule, where, message))

    def warn(rule: str, where: str, message: str) -> None:
        report.warnings.append(Finding(rule, where, message))

    if ds.format != "mestra/0":
        error("E01", "/", "this reader accepts mestra/0 and the "
                          "dataset says %r" % ds.format)
        return report
    for name, value in (("writer", ds.writer), ("created", ds.created)):
        if not value:
            error("E17", "/", "the root attribute %s is missing" % name)
    if not _is_iso_utc(ds.created):
        warn("W14", "/", "created is not an ISO 8601 UTC timestamp")
    groups = [k for k in ds.keys.values() if k.role == "group"]
    if groups and not ds.generalisation_group:
        error("E39", "/", "a file that declares a group key names the "
                          "unit of generalisation")

    counted: dict[str, int] = {}
    for name in ds.key_names():
        key = ds.keys[name]
        where = "/keys/" + name
        if key.role not in KEY_ROLES:
            error("E02", where, "%r is not a key role of section 3"
                  % key.role)
            continue
        counted[key.role] = counted.get(key.role, 0) + 1
        if key.role in ("design", "condition", "time") and not key.units:
            error("E39", where, "a %s key carries units" % key.role)
        if key.units and not is_parseable(key.units):
            warn("W10", where, "the units string %r does not parse"
                 % key.units)
        if key.role in ("categorical", "group", "split", "status"):
            table = ds.categories.get(key.category or "")
            if table is None:
                error("E39", where, "a %s key names its category table"
                      % key.role)
            elif key.data is not None:
                values = np.asarray(key.data.read())
                if values.size and ((values < 0)
                                    | (values >= len(table))).any():
                    error("E10", where, "a value is outside a category "
                                        "table of %d entries"
                          % len(table))
        if key.data is not None and int(key.data.shape[0]) != ds.n_rows:
            error("E16", where, "this holds %d rows where the dataset "
                                "has %d"
                  % (int(key.data.shape[0]), ds.n_rows))
    for role, limit in KEY_ROLES.items():
        if limit is not None and counted.get(role, 0) > limit:
            error("E03", "/keys", "a file has at most %d key with the "
                                  "role %s" % (limit, role))

    for name, slot in sorted(ds.scalars.items()):
        where = "/scalars/" + name
        if not slot.units:
            error("E11", where, "a scalar carries units")
        elif not is_parseable(slot.units):
            warn("W10", where, "the units string %r does not parse"
                 % slot.units)
        _check_source(ds, slot, where, error)
        if slot.data is not None:
            values = np.asarray(slot.data.read())
            if values.size and not np.isfinite(values).all():
                warn("W03", where, "a non-finite value")
            if int(values.shape[0]) != ds.n_rows:
                error("E16", where, "this holds %d rows where the "
                                    "dataset has %d"
                      % (int(values.shape[0]), ds.n_rows))

    for sname in ds.support_names():
        support = ds.supports[sname]
        where = "/supports/" + sname
        if support.kind in ("mesh", "axis") and \
                support.coordinates is None:
            error("E03", where, "a %s support has exactly one "
                                "coordinates array" % support.kind)
        if support.kind == "mesh" and support.cell_types is None:
            error("E38", where, "a mesh support carries cell_types, "
                                "cell_offsets and cell_connectivity")
        if support.stored_support_id is not None and \
                support.stored_support_id != support.computed_support_id():
            error("E08", where, "the stored support_id does not match "
                                "the arrays")
        for slot_name, array in support.arrays().items():
            slot_where = "%s/%s" % (where, slot_name)
            if array.role not in ARRAY_ROLES:
                error("E02", slot_where, "%r is not an array role of "
                                         "section 3" % array.role)
            if array.role == "field" and not array.units:
                error("E11", slot_where, "a field carries units")
            if array.units and not is_parseable(array.units):
                warn("W10", slot_where, "the units string %r does not "
                                        "parse" % array.units)
            if array.role == "derived" and not (array.derived_from
                                                and array.recipe):
                error("E13", slot_where, "a derived array carries "
                                         "derived_from and recipe")
            if (array.role in ("weight", "normal")
                    and not array.recomputed):
                warn("W06", slot_where, "%s arrays are recomputed from "
                                        "the connectivity, never "
                                        "imported" % array.role)
            if array.name == "coordinates" and support.kind == "axis" \
                    and array.varies != "none":
                error("E35", slot_where, "the coordinates of an axis "
                                         "support have varies = none")
            _check_source(ds, array, slot_where, error)
    if len(ds.supports) > 1:
        warn("W05", "/supports", "the dataset declares %d supports, so "
                                 "index-aligned operations are not "
                                 "available" % len(ds.supports))
        if not ds.has_row_support:
            error("E28", "/", "an unaligned file carries a "
                              "/row_support for every row")
    elif ds.has_row_support:
        error("E28", "/row_support", "an aligned file carries no "
                                     "/row_support")
    return report


def _check_source(ds: Dataset, slot: Any, where: str,
                  error: Any) -> None:
    if slot.source == "data":
        if slot.data is None:
            error("E30", where, "a slot whose source is data holds "
                                "data")
        return
    if not slot.source.startswith("callable:"):
        error("E36", where, "source is data or callable:<id>, and this "
                            "is %r" % slot.source)
        return
    if (slot.callable_id or "") not in ds.callables:
        error("E14", where, "the dataset holds no callable called %r"
              % slot.callable_id)

