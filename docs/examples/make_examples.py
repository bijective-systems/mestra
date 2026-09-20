"""Write the two example files of docs/example.md with h5py alone.

Run it with any Python that has h5py and numpy:

    python make_examples.py

It writes mesh_two_rows.mes and affine_zero_rows.mes next to itself,
and prints the support_id it computed. Nothing here is a mestra
implementation; it is the specification read literally, so that an
implementer can compare a file byte for byte against the rules of
SPEC.md sections 18 to 25.
"""

import hashlib
import os

import h5py
import numpy as np

CREATED = "2026-09-19T00:00:00Z"
WRITER = "mestra examples 0"

# Section 21: the NAME attribute of a dimension scale that has no
# coordinate variable. 53 characters, then the length in ten columns.
DIM_NAME = "This is a netCDF dimension but not a netCDF variable."


# --------------------------------------------------------------- bits

def sdtype(nbytes):
    """Fixed-length UTF-8, NUL-padded (sections 18 and 19)."""
    return h5py.string_dtype(encoding="utf-8", length=max(1, nbytes))


def sattr(obj, name, value):
    """Write one string attribute the way section 18 requires."""
    raw = value.encode("utf-8")
    n = max(1, len(raw))
    obj.attrs.create(name, np.void(raw.ljust(n, b"\0")).tobytes(),
                     dtype=sdtype(n))


def battr(obj, name, value):
    obj.attrs.create(name, np.int8(1 if value else 0))


def iattr(obj, name, value):
    obj.attrs.create(name, np.int64(value))


def fattr(obj, name, value):
    obj.attrs.create(name, np.float64(value))


def strings(group, name, values, scale):
    """A one-dimensional fixed-length UTF-8 string dataset."""
    raw = [v.encode("utf-8") for v in values]
    n = max([len(r) for r in raw] + [1])
    d = group.create_dataset(name, shape=(len(raw),), dtype=sdtype(n),
                             data=[r.ljust(n, b"\0") for r in raw],
                             track_times=False)
    d.dims[0].attach_scale(scale)
    return d


def scale(group, name, length, unlimited=False):
    """A dimension scale, written as netCDF-C writes one (section 21).

    Attribute creation order is tracked and indexed so that the
    scale's REFERENCE_LIST can live in the file's heap; without it a
    scale takes at most 4085 attachments. Object time tracking is off
    in the same property list, because the version 2 object header
    the first call brings records four timestamps otherwise.
    """
    dcpl = h5py.h5p.create(h5py.h5p.DATASET_CREATE)
    dcpl.set_attr_creation_order(h5py.h5p.CRT_ORDER_TRACKED |
                                 h5py.h5p.CRT_ORDER_INDEXED)
    dcpl.set_obj_track_times(False)
    dcpl.set_chunk((1,) if unlimited else (max(1, length),))
    space = h5py.h5s.create_simple(
        (length,), (h5py.h5s.UNLIMITED,) if unlimited else (length,))
    tid = h5py.h5t.py_create(np.dtype(">f4"), logical=True)
    d = h5py.Dataset(h5py.h5d.create(group.id, name.encode("utf-8"),
                                     tid, space, dcpl=dcpl))
    d.make_scale("%s%10d" % (DIM_NAME, length))
    return d


def chunk_rows(itemsize, rest, n_rows):
    """The default of section 23: about 1 MiB of rows, at least one."""
    if n_rows == 0:
        return 1
    b = itemsize
    for extent in rest:
        b *= max(1, extent)
    c = 1048576 // b
    if c < 1:
        c = 1
    if c > n_rows:
        c = n_rows
    return c


def dataset(group, name, data, dtype, scales, n_rows=None):
    """A data slot. `scales` is one scale per axis, in order."""
    data = np.asarray(data, dtype=dtype)
    kw = {}
    if n_rows is not None:              # the row axis is unlimited
        kw["maxshape"] = (None,) + data.shape[1:]
        kw["chunks"] = ((chunk_rows(data.dtype.itemsize, data.shape[1:],
                                    n_rows),) + data.shape[1:])
    d = group.create_dataset(name, shape=data.shape, dtype=dtype,
                             data=data, track_times=False, **kw)
    for axis, s in enumerate(scales):
        d.dims[axis].attach_scale(s)
    return d


# ---------------------------------------------------------- the support

N_NODES = 6
CELL_TYPES = np.array([9, 9], dtype="<u1")           # two quadrilaterals
CELL_OFFSETS = np.array([0, 4, 8], dtype="<i8")
CELL_CONNECTIVITY = np.array([0, 1, 4, 3, 1, 2, 5, 4], dtype="<i8")


def support_id(n_nodes, cell_types, cell_offsets, connectivity,
               axis_coordinates=None):
    """Section 24."""
    h = hashlib.sha256()
    h.update(np.int64(n_nodes).astype("<i8").tobytes())
    h.update(np.asarray(cell_types, dtype="<u1").tobytes())
    h.update(np.asarray(cell_offsets, dtype="<i8").tobytes())
    h.update(np.asarray(connectivity, dtype="<i8").tobytes())
    if axis_coordinates is not None:
        h.update(np.asarray(axis_coordinates, dtype="<f8").tobytes())
    return h.hexdigest()


SUPPORT_ID = support_id(N_NODES, CELL_TYPES, CELL_OFFSETS,
                        CELL_CONNECTIVITY)


def write_support_cells(sup):
    """The three cell datasets and their dimension scales."""
    node = scale(sup, "node", N_NODES)
    cell = scale(sup, "cell", len(CELL_TYPES))
    cell_plus_one = scale(sup, "cell_plus_one", len(CELL_OFFSETS))
    index = scale(sup, "index", len(CELL_CONNECTIVITY))
    dataset(sup, "cell_types", CELL_TYPES, "<u1", [cell])
    dataset(sup, "cell_offsets", CELL_OFFSETS, "<i8", [cell_plus_one])
    dataset(sup, "cell_connectivity", CELL_CONNECTIVITY, "<i8", [index])
    sattr(sup, "kind", "mesh")
    iattr(sup, "n_nodes", N_NODES)
    iattr(sup, "n_cells", len(CELL_TYPES))
    sattr(sup, "support_id", SUPPORT_ID)
    return node, cell


# ----------------------------------------------------- example file one

def write_mesh_two_rows(path):
    """Two rows, one mesh support, one field, one label, one scalar."""
    f = h5py.File(path, "w")

    sattr(f, "created", CREATED)
    sattr(f, "format", "mestra/0")
    sattr(f, "writer", WRITER)
    battr(f, "aligned", True)
    sattr(f, "generalisation_group", "member")

    row = scale(f, "row", 2, unlimited=True)
    component_1 = scale(f, "component_1", 1)
    component_2 = scale(f, "component_2", 2)
    group_member = scale(f, "group_member", 2)
    category_member = scale(f, "category_member", 2)
    category_region = scale(f, "category_region", 2)

    categories = f.create_group("categories")
    strings(categories, "member", ["wing_a", "wing_b"], category_member)
    strings(categories, "region", ["inlet", "outlet"], category_region)

    keys = f.create_group("keys")
    mach = dataset(keys, "mach", [0.40, 0.80], "<f8", [row], n_rows=2)
    sattr(mach, "role", "condition")
    sattr(mach, "units", "1")
    fattr(mach, "lower", 0.1)
    fattr(mach, "upper", 0.9)

    member = dataset(keys, "member", [0, 1], "<i4", [row], n_rows=2)
    sattr(member, "role", "group")
    sattr(member, "category", "member")

    scalars = f.create_group("scalars")
    cl = dataset(scalars, "cl", [0.25, 0.55], "<f8", [row], n_rows=2)
    sattr(cl, "units", "1")
    sattr(cl, "source", "data")

    sup = f.create_group("supports").create_group("s0")
    node, cell = write_support_cells(sup)

    # Coordinates vary along the group key: one geometry per member.
    base = np.array([[0.0, 0.0], [1.0, 0.0], [2.0, 0.0],
                     [0.0, 1.0], [1.0, 1.0], [2.0, 1.0]])
    coords = np.stack([base, base * np.array([1.5, 1.0])])
    c = dataset(sup, "coordinates", coords, "<f8",
                [group_member, node, component_2])
    sattr(c, "role", "coordinates")
    sattr(c, "varies", "group:member")
    sattr(c, "units", "m")
    iattr(c, "components", 2)
    sattr(c, "source", "data")

    node_arrays = sup.create_group("node_arrays")
    p = dataset(node_arrays, "pressure",
                np.array([[[101.0], [102.0], [103.0],
                           [104.0], [105.0], [106.0]],
                          [[201.0], [202.0], [203.0],
                           [204.0], [205.0], [206.0]]]),
                "<f8", [row, node, component_1], n_rows=2)
    sattr(p, "role", "field")
    sattr(p, "varies", "row")
    sattr(p, "units", "Pa")
    iattr(p, "components", 1)
    sattr(p, "source", "data")

    cell_arrays = sup.create_group("cell_arrays")
    r = dataset(cell_arrays, "region", [[0], [1]], "<i4",
                [cell, component_1])
    sattr(r, "role", "label")
    sattr(r, "varies", "none")
    iattr(r, "components", 1)
    sattr(r, "source", "data")
    sattr(r, "category", "region")

    f.close()


# ----------------------------------------------------- example file two

AFFINE_KEYS = ["mach", "alpha"]
AFFINE = {
    "cl": {
        "A": np.array([[2.0, 0.1]]),
        "b": np.array([0.05]),
        "shape": np.array([], dtype="<i8"),
    },
    "pressure": {
        "A": np.array([[1.0, 0.0], [2.0, 0.0], [3.0, 0.5],
                       [4.0, 0.5], [5.0, 1.0], [6.0, 1.0]]),
        "b": np.array([0.0, 0.1, 0.2, 0.3, 0.4, 0.5]),
        "shape": np.array([6, 1], dtype="<i8"),
    },
}


def codec_array(group, name, data):
    """A dictionary dataset with its `mestra_<name>_d<i>` scales."""
    data = np.asarray(data)
    empty = 0 in data.shape
    d = group.create_dataset(
        name, shape=data.shape, dtype=data.dtype.newbyteorder("<"),
        data=data, track_times=False,
        maxshape=(None,) * data.ndim if empty else None,
        chunks=(1,) * data.ndim if empty else None)
    for axis, length in enumerate(data.shape):
        s = scale(group, "mestra_%s_d%d" % (name, axis), length,
                  unlimited=(length == 0))
        d.dims[axis].attach_scale(s)
    return d


def write_affine_zero_rows(path):
    """No rows, the same support, two slots served by one callable."""
    f = h5py.File(path, "w")

    sattr(f, "created", CREATED)
    sattr(f, "format", "mestra/0")
    sattr(f, "writer", WRITER)
    battr(f, "aligned", True)

    row = scale(f, "row", 0, unlimited=True)
    component_2 = scale(f, "component_2", 2)

    keys = f.create_group("keys")
    alpha = dataset(keys, "alpha", np.zeros(0), "<f8", [row], n_rows=0)
    sattr(alpha, "role", "condition")
    sattr(alpha, "units", "degree")
    fattr(alpha, "lower", -2.0)
    fattr(alpha, "upper", 10.0)

    mach = dataset(keys, "mach", np.zeros(0), "<f8", [row], n_rows=0)
    sattr(mach, "role", "condition")
    sattr(mach, "units", "1")
    fattr(mach, "lower", 0.1)
    fattr(mach, "upper", 0.9)

    # A slot served by a callable is a group, not a dataset.
    cl = f.create_group("scalars").create_group("cl")
    sattr(cl, "units", "1")
    sattr(cl, "source", "callable:m1")
    sattr(cl, "output", "cl")

    sup = f.create_group("supports").create_group("s0")
    node, _cell = write_support_cells(sup)

    base = np.array([[0.0, 0.0], [1.0, 0.0], [2.0, 0.0],
                     [0.0, 1.0], [1.0, 1.0], [2.0, 1.0]])
    c = dataset(sup, "coordinates", base, "<f8", [node, component_2])
    sattr(c, "role", "coordinates")
    sattr(c, "varies", "none")
    sattr(c, "units", "m")
    iattr(c, "components", 2)
    sattr(c, "source", "data")

    p = sup.create_group("node_arrays").create_group("pressure")
    sattr(p, "role", "field")
    sattr(p, "varies", "row")
    sattr(p, "units", "Pa")
    iattr(p, "components", 1)
    sattr(p, "source", "callable:m1")
    sattr(p, "output", "pressure")

    m1 = f.create_group("callables").create_group("m1")
    sattr(m1, "type", "affine")
    sattr(m1, "repr", "affine(mach, alpha -> cl, pressure)")
    scale_keys = scale(m1, "mestra_keys_d0", len(AFFINE_KEYS))
    strings(m1, "keys", AFFINE_KEYS, scale_keys)

    outputs = m1.create_group("outputs")
    for slot in sorted(AFFINE):
        g = outputs.create_group(slot)
        for name in ("A", "b", "shape"):
            codec_array(g, name, AFFINE[slot][name])

    f.close()


def evaluate_affine(slot, values):
    """Section 27, so that the worked numbers can be re-derived."""
    entry = AFFINE[slot]
    x = np.array([values[k] for k in AFFINE_KEYS], dtype="<f8")
    y = entry["A"] @ x + entry["b"]
    return y.reshape([int(n) for n in entry["shape"]])


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    write_mesh_two_rows(os.path.join(here, "mesh_two_rows.mes"))
    write_affine_zero_rows(os.path.join(here, "affine_zero_rows.mes"))
    print("support_id", SUPPORT_ID)
    at = {"mach": 0.5, "alpha": 4.0}
    print("affine cl      ", evaluate_affine("cl", at))
    print("affine pressure", evaluate_affine("pressure", at).ravel())
