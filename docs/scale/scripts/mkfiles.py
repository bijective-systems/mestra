"""Build conforming mestra files with N row-dimensioned datasets.

A golden corpus case is copied object by object into a new file with
extra scalar columns and a chosen HDF5 layout. Every datatype is
reused from the seed by its HDF5 type id, so the byte encodings of
section 18 and section 19 survive; nothing else is copied at the HDF5
level, so the object header layout of the result is set entirely by
the property lists below.

    mkfiles.py SEED.mes OUTDIR N [N ...] [--layouts a,b,c]
                                        [--unlimited SCALE]

`--unlimited` names a dimension scale, by its link name, whose
dimension is made unlimited wherever it is used; `--unlimited draw_3`
on the corpus case `draws_and_summaries` is the file section 4 of the
report is about.

Layouts are the property choices under test:

    default        the library defaults, which is what three of the
                   four writers produce: version 1 object headers
                   throughout.
    latest         H5Pset_libver_bounds(fapl, LATEST, LATEST): version
                   2 object headers on every object, which is the
                   layout Julia's writer produces.
    latest-notimes the same, with H5Pset_obj_track_times(gcpl, 0) on
                   every group as well as every dataset.
    v18            H5Pset_libver_bounds(fapl, V18, LATEST).
    scale-order    the defaults, except that each dimension scale
                   alone is created with
                       H5Pset_attr_creation_order(dcpl, TRACKED)
                       H5Pset_obj_track_times(dcpl, 0)
                   which gives those objects a version 2 header and
                   leaves every other object at version 1.
    scale-nc       the same with TRACKED | INDEXED, which is what
                   netCDF-C sets on every object it creates.
    scale-phase    the defaults, except that each dimension scale
                   alone is created with
                   H5Pset_attr_phase_change(dcpl, 0, 0).

Every dataset is created with object time tracking off, as the corpus
generator does, so that two runs give the same bytes.
"""

from __future__ import annotations

import os
import sys

import h5py
import numpy as np

REF_ATTRS = ("REFERENCE_LIST", "DIMENSION_LIST")
LAYOUTS = ("default", "latest", "latest-notimes", "v18", "scale-order",
           "scale-nc", "scale-phase")


def copy_attr(src_obj, dst_obj, name):
    """Recreate one attribute with the datatype the seed gave it."""
    aid = h5py.h5a.open(src_obj.id, name.encode())
    tid, sid = aid.get_type(), aid.get_space()
    buf = np.empty(sid.shape, dtype="|V%d" % tid.get_size())
    aid.read(buf, mtype=tid)
    out = h5py.h5a.create(dst_obj.id, name.encode(), tid, sid)
    out.write(buf, mtype=tid)


def copy_attrs(src_obj, dst_obj):
    for name in src_obj.attrs:
        if name not in REF_ATTRS:
            copy_attr(src_obj, dst_obj, name)


def is_scale(obj):
    return obj.attrs.get("CLASS", b"") == b"DIMENSION_SCALE"


def make_group(dst, name, layout):
    """A group, with object time tracking off in the -notimes layouts.

    A version 2 object header records four timestamps unless the
    creating property list says otherwise, and h5py's own default for
    a group leaves them on, so a file written under the latest bounds
    is not byte reproducible until this is set.
    """
    if not layout.endswith("-notimes"):
        return dst.create_group(name)
    gcpl = h5py.h5p.create(h5py.h5p.GROUP_CREATE)
    gcpl.set_obj_track_times(False)
    parent, _, leaf = name.rpartition("/")
    loc = dst[parent] if parent else dst
    gid = h5py.h5g.create(loc.id, leaf.encode(), gcpl=gcpl)
    return h5py.Group(gid)


def make_fapl(layout):
    if layout in ("default", "scale-order", "scale-nc", "scale-phase"):
        return None
    fapl = h5py.h5p.create(h5py.h5p.FILE_ACCESS)
    if layout.startswith("latest"):
        fapl.set_libver_bounds(h5py.h5f.LIBVER_LATEST,
                               h5py.h5f.LIBVER_LATEST)
    elif layout == "v18":
        fapl.set_libver_bounds(h5py.h5f.LIBVER_V18,
                               h5py.h5f.LIBVER_LATEST)
    else:
        raise ValueError(layout)
    return fapl


def open_out(path, layout):
    """The new file.

    The root group is created with the file creation property list, so
    turning object time tracking off for it is a third call in a third
    place: H5Pset_obj_track_times on the fcpl, on every gcpl, and on
    every dcpl.
    """
    fapl = make_fapl(layout)
    fcpl = None
    if layout.endswith("-notimes"):
        fcpl = h5py.h5p.create(h5py.h5p.FILE_CREATE)
        fcpl.set_obj_track_times(False)
    if fapl is None and fcpl is None:
        return h5py.File(path, "w")
    return h5py.File(h5py.h5f.create(path.encode(), h5py.h5f.ACC_TRUNC,
                                     fcpl=fcpl, fapl=fapl))


def make_dcpl(chunks, layout, scale):
    dcpl = h5py.h5p.create(h5py.h5p.DATASET_CREATE)
    dcpl.set_obj_track_times(False)
    if chunks is not None:
        dcpl.set_chunk(tuple(chunks))
    if scale and layout == "scale-order":
        dcpl.set_attr_creation_order(h5py.h5p.CRT_ORDER_TRACKED)
    if scale and layout == "scale-nc":
        dcpl.set_attr_creation_order(h5py.h5p.CRT_ORDER_TRACKED |
                                     h5py.h5p.CRT_ORDER_INDEXED)
    if scale and layout == "scale-phase":
        dcpl.set_attr_phase_change(0, 0)
    return dcpl


def clone_dataset(src, dst_parent, leaf, layout, scale, gzip=None,
                  unlimited_axes=()):
    """Create the same dataset in the output, values and all.

    `unlimited_axes` names axes whose maximum extent is to be made
    unlimited even though the seed gives them a length; a dataset with
    one must be chunked, so a contiguous one is given a chunk equal to
    its extent.
    """
    tid = src.id.get_type()
    maxshape = [h5py.h5s.UNLIMITED if m is None else m
                for m in src.maxshape]
    chunks = src.chunks
    for axis in unlimited_axes:
        maxshape[axis] = h5py.h5s.UNLIMITED
    if unlimited_axes and chunks is None:
        chunks = tuple(max(1, n) for n in src.shape)
    if unlimited_axes and scale:
        # section 21: an unlimited scale is chunked with length 1
        chunks = (1,)
    sid = h5py.h5s.create_simple(src.shape, tuple(maxshape))
    dcpl = make_dcpl(chunks, layout, scale)
    if gzip is not None and src.chunks is not None:
        dcpl.set_deflate(gzip)
    dsid = h5py.h5d.create(dst_parent.id, leaf.encode(), tid, sid,
                           dcpl=dcpl)
    out = h5py.Dataset(dsid)
    if not scale and src.id.get_storage_size():
        buf = np.ascontiguousarray(
            np.empty(src.shape, dtype="|V%d" % tid.get_size()))
        src.id.read(h5py.h5s.ALL, h5py.h5s.ALL, buf, mtype=tid)
        out.id.write(h5py.h5s.ALL, h5py.h5s.ALL, buf, mtype=tid)
    return out


def build(seed, out, layout, n_slots, gzip=None, unlimited=None):
    """Write the seed again with n_slots row-dimensioned datasets.

    `unlimited` names a dimension scale, by link name, whose dimension
    is to be made unlimited wherever it is used.
    """
    with h5py.File(seed, "r") as src, open_out(out, layout) as dst:
        copy_attrs(src, dst)
        made, attach, scalar = {}, [], None

        def visit(name, obj):
            nonlocal scalar
            if isinstance(obj, h5py.Group):
                g = make_group(dst, name, layout)
                copy_attrs(obj, g)
                return
            parent = name.rsplit("/", 1)[0] if "/" in name else ""
            leaf = name.rsplit("/", 1)[-1]
            axes = []
            for axis, dim in enumerate(obj.dims):
                for s in dim.values():
                    if unlimited and s.name.lstrip("/") == unlimited:
                        axes.append(axis)
            if unlimited and name == unlimited:
                axes = [0]
            d = clone_dataset(obj, dst[parent] if parent else dst, leaf,
                              layout, is_scale(obj), gzip, tuple(axes))
            copy_attrs(obj, d)
            made[name] = d
            for axis, dim in enumerate(obj.dims):
                for s in dim.values():
                    attach.append((name, axis, s.name.lstrip("/")))
            if name.startswith("scalars/") and scalar is None:
                scalar = obj

        src.visititems(visit)

        have = sum(1 for n, a, s in attach if s == "row" and a == 0)
        for i in range(max(0, n_slots - have)):
            leaf = "q%06d" % i
            d = clone_dataset(scalar, dst["scalars"], leaf, layout,
                              False, gzip)
            copy_attrs(scalar, d)
            made["scalars/" + leaf] = d
            attach.append(("scalars/" + leaf, 0, "row"))

        for name, axis, s in attach:
            made[name].dims[axis].attach_scale(dst[s])
    return out


def main(argv):
    if len(argv) < 4:
        raise SystemExit(__doc__)
    seed, outdir = argv[1], argv[2]
    rest, layouts, unlimited = argv[3:], list(LAYOUTS), None
    if "--layouts" in rest:
        i = rest.index("--layouts")
        layouts = rest[i + 1].split(",")
        rest = rest[:i] + rest[i + 2:]
    if "--unlimited" in rest:
        i = rest.index("--unlimited")
        unlimited = rest[i + 1]
        rest = rest[:i] + rest[i + 2:]
    counts = [int(x) for x in rest] or [0]
    os.makedirs(outdir, exist_ok=True)
    for layout in layouts:
        for n in counts:
            tag = layout if unlimited is None else layout + "-unlimited"
            path = os.path.join(outdir, "n%05d_%s.mes" % (n, tag))
            try:
                build(seed, path, layout, n, unlimited=unlimited)
                print("%-12s %6d  %10d bytes  %s"
                      % (layout, n, os.path.getsize(path),
                         os.path.basename(path)))
            except Exception as exc:               # noqa: BLE001
                print("%-12s %6d  FAILED  %s: %s"
                      % (layout, n, type(exc).__name__,
                         str(exc).strip()[:60]))
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
