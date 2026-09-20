"""Fifteen files of my own, outside every existing hostile set.

Each is built here with h5py (or, for one of them, with netCDF-C
through the netCDF4 binding) from the rules of SPEC.md, so that the
input to this part of the verification comes from no implementation.
Each carries what I read the specification to require, which is the
claim the report argues, not an authority.

  python docs/verification/adversarial.py build DIR
"""

from __future__ import annotations

import json
import os
import shutil
import sys

import h5py
import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
DIM_NAME = "This is a netCDF dimension but not a netCDF variable."


def case(name):
    return os.path.join("vectors", "cases", name, "case.mes")


def sdtype(n):
    return h5py.string_dtype(encoding="utf-8", length=max(1, n))


def sattr(obj, name, value):
    raw = value.encode("utf-8") if isinstance(value, str) else value
    n = max(1, len(raw))
    obj.attrs.create(name, raw.ljust(n, b"\0"), dtype=sdtype(n))


def scale(group, name, length, unlimited=False):
    d = group.create_dataset(
        name, shape=(length,), dtype=">f4", track_times=False,
        maxshape=(None,) if unlimited else None,
        chunks=(1,) if unlimited else ((min(length, 4096),) if length else (1,)))
    sattr(d, "CLASS", "DIMENSION_SCALE")
    sattr(d, "NAME", "%s%10d" % (DIM_NAME, length))
    return d


def raw_attrs(obj):
    """name -> (value, exact HDF5 dtype), for recreating elsewhere."""
    out = {}
    for name in obj.attrs:
        aid = h5py.h5a.open(obj.id, name.encode("utf-8"))
        out[name] = (obj.attrs[name], aid.dtype)
    return out


def copy_attrs(src, dst, skip=()):
    """Copy attributes keeping the exact HDF5 type.

    `attrs.create(name, value)` would turn a fixed-length string into
    a variable-length one, which section 18 forbids, so the type comes
    from the source attribute itself.
    """
    for name in src.attrs:
        if name in skip:
            continue
        aid = h5py.h5a.open(src.id, name.encode("utf-8"))
        dst.attrs.create(name, src.attrs[name], dtype=aid.dtype)


def start(out, name, base="mesh_two_rows"):
    p = os.path.join(out, name + ".mes")
    shutil.copy(case(base), p)
    return p


BUILDERS = {}


def builder(fn):
    BUILDERS[fn.__name__] = fn
    return fn


# ------------------------------------------------------------ the set

@builder
def attr_role_is_an_integer(out):
    """Section 18: `role` is a string attribute. Here it is an int64,
    so the reader has no role at all. E19, and E02 is reasonable."""
    p = start(out, "attr_role_is_an_integer")
    with h5py.File(p, "r+") as f:
        d = f["/keys/mach"]
        del d.attrs["role"]
        d.attrs.create("role", np.int64(3))
    return p, ["E19"], "role stored as an int64 where section 18 has a string"


@builder
def attr_units_is_a_float(out):
    """The same for `units` on a field: a float64 where section 18
    requires a string. E19."""
    p = start(out, "attr_units_is_a_float")
    with h5py.File(p, "r+") as f:
        d = f["/supports/s0/node_arrays/pressure"]
        del d.attrs["units"]
        d.attrs.create("units", np.float64(1.0))
    return p, ["E19"], "units stored as a float64 where section 18 has a string"


@builder
def aligned_is_two(out):
    """Section 18: a boolean is int8 and `No other value is legal`.
    This one is 2. E19."""
    p = start(out, "aligned_is_two")
    with h5py.File(p, "r+") as f:
        del f.attrs["aligned"]
        f.attrs.create("aligned", np.int8(2))
    return p, ["E19"], "the boolean `aligned` holds 2"


@builder
def nul_inside_a_string_attribute(out):
    """Section 18: a string value must not contain a NUL byte, and
    the sentinel is the only exception. E26 covers a NUL anywhere but
    in the trailing padding."""
    p = start(out, "nul_inside_a_string_attribute")
    with h5py.File(p, "r+") as f:
        d = f["/supports/s0/node_arrays/pressure"]
        del d.attrs["units"]
        d.attrs.create("units", b"P\x00a", dtype=sdtype(3))
    return p, ["E26"], "a NUL byte in the middle of a string attribute"


@builder
def category_longer_than_two_to_the_31(out):
    """A category table that declares 2^31 + 5 entries and stores
    none. Section 29 caps an eager read at 2^31 elements, so this is
    E41 there; nothing may allocate it, and the pass must go on."""
    p = start(out, "category_longer_than_two_to_the_31")
    n = 2 ** 31 + 5
    with h5py.File(p, "r+") as f:
        del f["categories"]["region"]
        del f["category_region"]
        scale(f, "category_region", 0, unlimited=True)
        d = f["categories"].create_dataset(
            "region", shape=(n,), dtype=sdtype(6), chunks=(4096,),
            maxshape=(None,), track_times=False)
        d.dims[0].attach_scale(f["category_region"])
    return p, ["E41"], "a category table declaring 2^31 + 5 entries"


@builder
def unlimited_node_dimension(out):
    """Section 21 makes `row` the unlimited dimension and gives every
    other one a length. Here the support's `node` scale is unlimited
    too. netCDF-4 allows several unlimited dimensions, so this asks
    whether the four readers agree about a file the container does
    not reject."""
    p = start(out, "unlimited_node_dimension")
    with h5py.File(p, "r+") as f:
        s = f["/supports/s0"]
        keep = {}
        for name in ("coordinates",):
            d = s[name]
            keep[name] = (d[()], d.dtype, raw_attrs(d),
                          [dd[0].name.split("/")[-1] for dd in d.dims])
        for name in keep:
            del s[name]
        del s["node"]
        scale(s, "node", 6, unlimited=True)
        for name, (data, dt, attrs, dims) in keep.items():
            d = s.create_dataset(name, data=data, dtype=dt, track_times=False,
                                 maxshape=(None,) + data.shape[1:],
                                 chunks=(1,) * data.ndim)
            for k, (v, dt) in attrs.items():
                d.attrs.create(k, v, dtype=dt)
            for axis, dim in enumerate(dims):
                d.dims[axis].attach_scale(
                    s[dim] if dim in s else f[dim])
        for name in ("pressure",):
            d = s["node_arrays"][name]
            data, dt, attrs = d[()], d.dtype, raw_attrs(d)
            dims = [dd[0].name.split("/")[-1] for dd in d.dims]
            del s["node_arrays"][name]
            nd = s["node_arrays"].create_dataset(
                name, data=data, dtype=dt, track_times=False,
                maxshape=(None,) * data.ndim, chunks=(1,) * data.ndim)
            for k, (v, adt) in attrs.items():
                nd.attrs.create(k, v, dtype=adt)
            for axis, dim in enumerate(dims):
                nd.dims[axis].attach_scale(s[dim] if dim in s else f[dim])
    return p, [], "the support's `node` dimension made unlimited"


@builder
def scale_attached_to_itself(out):
    """A dimension scale attached to its own axis. Section 21 says a
    scale carries no scale on its own axis; nothing here may loop."""
    p = start(out, "scale_attached_to_itself")
    with h5py.File(p, "r+") as f:
        row = f["row"]
        # H5DSattach_scale refuses this, so the attribute the API
        # would have written is written by hand: a DIMENSION_LIST of
        # one entry, holding a reference to `row` itself.
        dt = h5py.vlen_dtype(h5py.ref_dtype)
        value = np.empty((1,), dtype=object)
        value[0] = np.array([row.ref], dtype=h5py.ref_dtype)
        row.attrs.create("DIMENSION_LIST", value, dtype=dt)
    return p, [], "a dimension scale whose own axis points back at it"


@builder
def row_support_negative(out):
    """Section 22: a /row_support value outside [0, number of
    supports) is E06. This one is -1."""
    p = start(out, "row_support_negative", base="two_supports_unaligned")
    with h5py.File(p, "r+") as f:
        rs = f["/row_support"]
        v = rs[()]
        v[0] = -1
        rs[...] = v
    return p, ["E06"], "a /row_support entry of -1"


@builder
def support_holds_a_dataset_called_row(out):
    """Section 21 lets a support carry a local `row` scale only in an
    unaligned file. This aligned file carries an ordinary dataset of
    that name, which netCDF-C reads as a variable shadowing nothing."""
    p = start(out, "support_holds_a_dataset_called_row")
    with h5py.File(p, "r+") as f:
        s = f["/supports/s0"]
        d = s.create_dataset("row", data=np.array([1.0, 2.0]),
                             dtype="<f8", track_times=False)
        d.dims[0].attach_scale(f["row"])
    return p, [], "a support carrying a plain dataset named `row`"


@builder
def callable_type_with_a_slash(out):
    """Section 18 constrains names, not attribute values, and
    section 10 says `type` is a public string. A slash in it is legal
    and must not be read as a path. This file must be accepted."""
    p = start(out, "callable_type_with_a_slash", base="affine_zero_rows")
    with h5py.File(p, "r+") as f:
        g = f["/callables/m1"]
        del g.attrs["type"]
        sattr(g, "type", "vendor/model v2")
    return p, [], "a callable whose `type` contains a slash; legal"


@builder
def keys_differing_only_by_case(out):
    """Two keys whose names differ only by case. Both are legal
    netCDF-4 names and the key order of section 26 is by UTF-8 bytes,
    so `Mach` comes before `mach`. This file must be accepted and
    both keys kept."""
    p = start(out, "keys_differing_only_by_case")
    with h5py.File(p, "r+") as f:
        src = f["/keys/mach"]
        d = f["/keys"].create_dataset(
            "Mach", data=src[()], dtype=src.dtype, track_times=False,
            maxshape=(None,), chunks=src.chunks)
        copy_attrs(src, d)
        d.dims[0].attach_scale(f["row"])
    return p, [], "two keys differing only by case; legal"


@builder
def support_id_in_upper_case(out):
    """Section 24: the attribute is the digest in lower-case
    hexadecimal. This one is upper case, so it does not match. E08."""
    p = start(out, "support_id_in_upper_case")
    with h5py.File(p, "r+") as f:
        s = f["/supports/s0"]
        got = s.attrs["support_id"]
        text = got.decode() if isinstance(got, bytes) else str(got)
        del s.attrs["support_id"]
        sattr(s, "support_id", text.upper())
    return p, ["E08"], "a support_id in upper-case hexadecimal"


@builder
def row_scale_length_disagrees(out):
    """Section 21: the row scale's own length must equal the row
    count, so that a reader can learn it from a file with no
    row-dimensioned dataset. Here the scale says 7 and the datasets
    hold 2."""
    p = start(out, "row_scale_length_disagrees")
    with h5py.File(p, "r+") as f:
        f["row"].resize((7,))
    return p, ["E16"], "the `row` scale says 7 where the datasets hold 2"


@builder
def four_thousand_keys(out):
    """A valid file with four thousand keys, which is about the most
    the default HDF5 layout can attach to one dimension scale: the
    scale's REFERENCE_LIST attribute reaches the 64 KiB limit at 4085
    attachments. Nothing here is malformed."""
    p = start(out, "four_thousand_keys")
    with h5py.File(p, "r+") as f:
        src = f["/keys/mach"]
        data, dt, chunks = src[()], src.dtype, src.chunks
        keys, row = f["/keys"], f["row"]
        for i in range(4000):
            d = keys.create_dataset("k%05d" % i, data=data, dtype=dt,
                                    track_times=False, maxshape=(None,),
                                    chunks=chunks)
            copy_attrs(src, d)
            d.dims[0].attach_scale(row)
    return p, [], "a valid file with four thousand keys"


@builder
def ten_thousand_keys(out):
    """A valid file with ten thousand keys. The default HDF5 layout
    cannot hold it -- see `four_thousand_keys` -- so this one is
    written with the newer object header format, which is the only
    way the container expresses it. It declares no support, which
    section 22 makes aligned."""
    p = os.path.join(out, "ten_thousand_keys.mes")
    if os.path.exists(p):
        os.remove(p)
    with h5py.File(p, "w", libver="latest") as f:
        sattr(f, "format", "mestra/0")
        sattr(f, "writer", "phase 3 verification")
        sattr(f, "created", "2026-09-20T00:00:00Z")
        f.attrs.create("aligned", np.int8(1))
        row = scale(f, "row", 2, unlimited=True)
        keys = f.create_group("keys")
        for i in range(10000):
            d = keys.create_dataset("k%05d" % i, data=np.array([0.4, 0.8]),
                                    dtype="<f8", track_times=False,
                                    maxshape=(None,), chunks=(2,))
            sattr(d, "role", "condition")
            sattr(d, "units", "1")
            d.dims[0].attach_scale(row)
        s = f.create_group("scalars")
        d = s.create_dataset("cl", data=np.array([0.25, 0.55]), dtype="<f8",
                             track_times=False, maxshape=(None,),
                             chunks=(2,))
        sattr(d, "units", "1")
        sattr(d, "source", "data")
        d.dims[0].attach_scale(row)
    return p, [], "a valid file with ten thousand keys, newer HDF5 layout"


@builder
def netcdf4_valid_mestra_invalid(out):
    """Written by netCDF-C itself, so the container is beyond doubt:
    a netCDF-4 file with `format = mestra/0` whose field is float32,
    which section 19 forbids anywhere. E20."""
    import netCDF4

    p = os.path.join(out, "netcdf4_valid_mestra_invalid.mes")
    if os.path.exists(p):
        os.remove(p)
    ds = netCDF4.Dataset(p, "w", format="NETCDF4")
    ds.setncattr("format", "mestra/0")
    ds.setncattr("writer", "netcdf-c by hand")
    ds.setncattr("created", "2026-09-20T00:00:00Z")
    ds.setncattr("aligned", np.int8(1))
    ds.createDimension("row", None)
    ds.createDimension("node", 3)
    ds.createDimension("component_1", 1)
    keys = ds.createGroup("keys")
    mach = keys.createVariable("mach", "f8", ("row",))
    mach.setncattr("role", "condition")
    mach.setncattr("units", "1")
    mach[:] = np.array([0.4, 0.8])
    sup = ds.createGroup("supports").createGroup("s0")
    sup.setncattr("kind", "axis")
    sup.setncattr("n_nodes", np.int64(3))
    sup.setncattr("n_cells", np.int64(0))
    sup.setncattr("support_id", "0" * 64)
    coords = sup.createVariable("coordinates", "f8",
                                ("node", "component_1"))
    coords.setncattr("role", "coordinates")
    coords.setncattr("varies", "none")
    coords.setncattr("units", "m")
    coords.setncattr("components", np.int64(1))
    coords.setncattr("source", "data")
    coords[:] = np.array([[0.0], [0.5], [1.0]])
    arrays = sup.createGroup("node_arrays")
    v = arrays.createVariable("pressure", "f4", ("row", "node",
                                                 "component_1"),
                              chunksizes=(2, 3, 1))
    v.setncattr("role", "field")
    v.setncattr("varies", "row")
    v.setncattr("units", "Pa")
    v.setncattr("components", np.int64(1))
    v.setncattr("source", "data")
    v[:] = np.zeros((2, 3, 1), dtype="f4")
    ds.close()
    return p, ["E20"], "a netCDF-C written file whose field is float32"


@builder
def private_and_notes(out):
    """Not malformed at all: a valid file carrying /notes and
    /private, which no case of the corpus does, so no cross-write
    test covers what a round trip does with them."""
    p = start(out, "private_and_notes")
    with h5py.File(p, "r+") as f:
        notes = f.create_group("notes")
        sattr(notes, "solver", "a solver 3.1")
        notes.attrs.create("runs", np.int64(4))
        private = f.create_group("private")
        sattr(private, "ticket", "XYZ-1")
        g = private.create_group("history")
        g.create_dataset("stamps", data=np.array([1.0, 2.0]), dtype="<f8",
                         track_times=False)
    return p, [], "a valid file carrying /notes and /private"


def main(argv):
    out = argv[2]
    os.makedirs(out, exist_ok=True)
    index = {}
    for name in sorted(BUILDERS):
        try:
            path, ids, why = BUILDERS[name](out)
            index[name] = {"file": path, "required_errors": ids,
                           "description": why}
            print("built %-38s %s" % (name, ids or "must be accepted"))
        except Exception as exc:
            print("FAILED %-38s %s: %s" % (name, type(exc).__name__, exc))
    with open(os.path.join(out, "index.json"), "w") as fh:
        json.dump(index, fh, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
