"""Post-processing written against the format and nothing else.

Four operations that need no knowledge of where a file came from:
statistics of a field per row and per region, integration of a field
over a region with a weight array, a time series at one node along a
trajectory, and a split that honours the unit of generalisation.

They work the same on solver output and on the result of evaluating
a callable, because both are the same file.
"""

from __future__ import annotations

import warnings
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import numpy as np

from .errors import MestraError
from .model import ArraySlot, Dataset, Support

__all__ = [
    "Statistics",
    "field_statistics",
    "integrate",
    "time_series",
    "grouped_split",
    "split_leaks",
    "find_array",
]


# ----------------------------------------------------------- finding it

def find_array(dataset: Dataset, name: str,
               support: str | None = None) -> tuple[Support, ArraySlot]:
    """The support and slot an array name refers to.

    `name` may be "pressure" or "s0/pressure" or
    "node_arrays/pressure"; the support is named when more than one
    holds an array of that name.
    """
    if "/" in name and support is None:
        head, name = name.rsplit("/", 1)
        if head not in ("node_arrays", "cell_arrays"):
            support = head
    found = []
    for sname in dataset.support_names():
        if support is not None and sname != support:
            continue
        one = dataset.supports[sname]
        for slot_name, slot in one.arrays().items():
            if slot_name.rsplit("/", 1)[-1] == name:
                found.append((one, slot))
    if not found:
        raise MestraError(
            "E05", "no array called %r on %s" % (
                name, "support " + support if support
                else "any support"), name)
    if len(found) > 1:
        raise MestraError(
            "W05", "%d supports carry an array called %r; name the "
            "support as well" % (len(found), name), name)
    return found[0]


def _rows_of(dataset: Dataset, support: Support,
             slot: ArraySlot) -> np.ndarray:
    """The file row of each entry along a slot's leading dimension.

    In an unaligned file a row-varying array holds one entry per row
    referencing its support, in the file's row order (section 22).
    """
    if slot.varies != "row":
        raise MestraError(
            "section 5", "this array varies along %s, not along the "
            "row" % slot.varies, slot.name)
    return np.asarray(dataset.rows_on(support))


def _values(slot: ArraySlot) -> np.ndarray:
    values = np.asarray(slot.read().values)
    if slot.varies == "none":
        return values[None, ...]
    return values


# ------------------------------------------------------------ statistics

@dataclass
class Statistics:
    """Per-field statistics, per row and per region.

    `rows` holds the file row of each row of the tables; `regions`
    names the region of each column, or is None when the field was
    not grouped. Every table has the shape (rows, regions,
    components).
    """

    name: str
    units: str | None
    rows: np.ndarray
    regions: list[str] | None
    count: np.ndarray
    minimum: np.ndarray
    maximum: np.ndarray
    mean: np.ndarray
    std: np.ndarray

    def as_table(self, component: int = 0) -> list[dict[str, Any]]:
        """One dictionary per row and region, for printing."""
        out = []
        for at, row in enumerate(self.rows):
            for region in range(self.count.shape[1]):
                out.append({
                    "row": int(row),
                    "region": (self.regions[region] if self.regions
                               else None),
                    "count": int(self.count[at, region, component]),
                    "min": float(self.minimum[at, region, component]),
                    "max": float(self.maximum[at, region, component]),
                    "mean": float(self.mean[at, region, component]),
                    "std": float(self.std[at, region, component]),
                })
        return out


def field_statistics(dataset: Dataset, field: str, *,
                     support: str | None = None,
                     label: str | None = None) -> Statistics:
    """Statistics of a field, per row and per region label.

    `label` names a label array on the same support and the same
    location; without it the statistics are over every node or cell.
    Non-finite values are left out of the count and of the
    statistics, which is how this format spells missing data (W03).
    """
    one, slot = find_array(dataset, field, support)
    values = _values(slot)
    rows = (_rows_of(dataset, one, slot) if slot.varies == "row"
            else np.arange(values.shape[0]))
    if "draw" in slot.dims:
        raise MestraError(
            "section 9", "this slot holds draws; take the statistics "
            "of the draws it is the base of, or select a draw first",
            slot.name)
    groups, regions = _regions(dataset, one, slot, label)
    shape = (values.shape[0], len(groups), values.shape[-1])
    count = np.zeros(shape, dtype="i8")
    low = np.full(shape, np.nan)
    high = np.full(shape, np.nan)
    mean = np.full(shape, np.nan)
    std = np.full(shape, np.nan)
    for at, where in enumerate(groups):
        part = values[:, where, :]
        good = np.isfinite(part)
        count[:, at, :] = good.sum(axis=1)
        if not part.shape[1]:
            continue
        masked = np.where(good, part, np.nan)
        # A row with nothing finite in it keeps the NaN it starts
        # with; numpy would say so with a warning, and the count
        # already says it.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            low[:, at, :] = np.nanmin(masked, axis=1)
            high[:, at, :] = np.nanmax(masked, axis=1)
            mean[:, at, :] = np.nanmean(masked, axis=1)
            std[:, at, :] = np.nanstd(masked, axis=1)
    return Statistics(slot.name, slot.units, rows, regions, count, low,
                      high, mean, std)


def _regions(dataset: Dataset, support: Support, slot: ArraySlot,
             label: str | None) -> tuple[list[Any], list[str] | None]:
    """The node or cell indices of each region, and its name."""
    width = (support.n_nodes if slot.location == "node"
             else support.n_cells)
    if label is None:
        return [np.arange(width)], None
    arrays = (support.node_arrays if slot.location == "node"
              else support.cell_arrays)
    if label not in arrays:
        raise MestraError(
            "E05", "no label called %r on the %ss of support %s"
            % (label, slot.location, support.name), label)
    values = np.asarray(arrays[label].read().values)
    if arrays[label].varies != "none":
        raise MestraError(
            "section 5", "this label varies along %s; only a label "
            "that does not vary groups a whole field"
            % arrays[label].varies, label)
    flat = values.reshape(-1)
    table = dataset.categories.get(arrays[label].category or "")
    ids = sorted({int(v) for v in flat})
    names = [table[i] if table and 0 <= i < len(table) else str(i)
             for i in ids]
    return [np.flatnonzero(flat == i) for i in ids], names


# ----------------------------------------------------------- integration

def integrate(dataset: Dataset, field: str, *, weight: str,
              support: str | None = None, label: str | None = None,
              region: str | None = None) -> np.ndarray:
    """Integrate a field over a support, or over one region of it.

    `weight` names a weight array at the same location, which
    section 3 says is recomputed from the connectivity and never
    imported. The result has the shape (rows, components), and its
    units are the field's times the weight's.
    """
    one, slot = find_array(dataset, field, support)
    arrays = (one.node_arrays if slot.location == "node"
              else one.cell_arrays)
    if weight not in arrays:
        raise MestraError(
            "E05", "no array called %r on the %ss of support %s"
            % (weight, slot.location, one.name), weight)
    measure = arrays[weight]
    if measure.role != "weight":
        raise MestraError(
            "E02", "%r has the role %s; integration takes an array "
            "with the role weight" % (weight, measure.role), weight)
    values = _values(slot)
    w = np.asarray(measure.read().values).reshape(-1)
    where = slice(None)
    if label is not None:
        groups, names = _regions(dataset, one, slot, label)
        if region is None:
            raise MestraError(
                "section 3", "name the region to integrate over, one "
                "of %s" % ", ".join(names or []), label)
        if names is None or region not in names:
            raise MestraError(
                "E10", "no region called %r; this label has %s"
                % (region, ", ".join(names or [])), label)
        where = groups[names.index(region)]
    part = values[:, where, :]
    weights = w[where].reshape(1, -1, 1)
    return np.nansum(part * weights, axis=1)


# ----------------------------------------------------------- time series

def time_series(dataset: Dataset, field: str, *, node: int,
                trajectory: Any = None, component: int = 0,
                support: str | None = None
                ) -> tuple[np.ndarray, np.ndarray]:
    """One node's history along a trajectory.

    A trajectory is the set of rows sharing one value of the group
    the time key names as its trajectory_group (section 7). The
    result is the times and the values, in increasing time.
    """
    times = dataset.keys_of_role("time")
    if not times:
        raise MestraError(
            "section 7", "this file declares no time key, so it holds "
            "no trajectory")
    time = times[0]
    t = np.asarray(time.read().values)
    rows = np.arange(dataset.n_rows)
    if time.trajectory_group:
        group = dataset.keys.get(time.trajectory_group)
        if group is None:
            raise MestraError(
                "E39", "the time key names the trajectory group %r, "
                "and the file has no such key" % time.trajectory_group,
                time.name)
        labels = np.asarray(group.read().values)
        if trajectory is None:
            raise MestraError(
                "section 7", "name the trajectory, one of %s"
                % ", ".join(str(v) for v in sorted(set(labels.tolist()))),
                group.name)
        wanted = trajectory
        table = dataset.categories.get(group.category or "")
        if isinstance(trajectory, str):
            if table is None:
                raise MestraError(
                    "E39", "the group key %r has no category table, so "
                    "name the trajectory by its id" % group.name,
                    group.name)
            wanted = table.id_of(trajectory)
        rows = np.flatnonzero(labels == wanted)
    one, slot = find_array(dataset, field, support)
    values = _values(slot)
    if slot.varies == "row":
        on_support = _rows_of(dataset, one, slot)
        at = [int(np.flatnonzero(on_support == r)[0]) for r in rows
              if r in on_support]
    else:
        at = [0] * len(rows)
    order = np.argsort(t[rows], kind="stable")
    rows = rows[order]
    at = [at[i] for i in order]
    index: list[Any] = [np.asarray(at), node, component]
    if "draw" in slot.dims:
        index.insert(1, slice(None))
    return t[rows], values[tuple(index)]


# -------------------------------------------------------------- splitting

def split_leaks(dataset: Dataset,
                split: str | None = None) -> dict[Any, list[int]]:
    """The generalisation units a split places on both sides (W01).

    An empty result means the split is a generalisation test.
    """
    unit = dataset.generalisation_group
    if not unit or unit not in dataset.keys:
        return {}
    keys = [dataset.keys[split]] if split else \
        dataset.keys_of_role("split")
    if not keys:
        return {}
    labels = np.asarray(dataset.keys[unit].read().values)
    out: dict[Any, list[int]] = {}
    table = dataset.categories.get(dataset.keys[unit].category or "")
    for key in keys:
        values = np.asarray(key.read().values)
        for one in np.unique(labels):
            sides = np.unique(values[labels == one])
            if len(sides) > 1:
                name = table[int(one)] if table and \
                    0 <= int(one) < len(table) else int(one)
                out[name] = [int(s) for s in sides]
    return out


def grouped_split(dataset: Dataset,
                  fractions: Mapping[str, float] | None = None,
                  seed: int = 0) -> dict[str, np.ndarray]:
    """Split the rows by the unit of generalisation.

    Whole units move together, so no unit lands on both sides. The
    result maps each part's name to the file rows in it. A file that
    names no unit of generalisation cannot be split this way and the
    call is refused: a split by row would score the model on a case
    it has already seen.
    """
    unit = dataset.generalisation_group
    if not unit or unit not in dataset.keys:
        raise MestraError(
            "W01", "this file names no unit of generalisation, so a "
            "split cannot honour one; a split by row would put rows "
            "of one case on both sides")
    parts = dict(fractions or {"train": 0.8, "test": 0.2})
    total = sum(parts.values())
    if total <= 0:
        raise MestraError("W01", "the fractions must add to more than "
                                 "zero")
    labels = np.asarray(dataset.keys[unit].read().values)
    units = np.unique(labels)
    order = np.random.default_rng(seed).permutation(len(units))
    shuffled = units[order]
    out: dict[str, np.ndarray] = {}
    at = 0
    names = list(parts)
    for which, name in enumerate(names):
        take = (len(units) - at if which == len(names) - 1
                else int(round(len(units) * parts[name] / total)))
        take = max(0, min(take, len(units) - at))
        mine = shuffled[at:at + take]
        at += take
        rows = np.flatnonzero(np.isin(labels, mine))
        out[name] = rows
    return out

