"""The 4085 ceiling: reproduce it, then lift it.

Writes a file holding N datasets that all share one `row` dimension
scale, under a choice of HDF5 properties, and reports which HDF5 call
fails and why. The file it writes here is plain HDF5 and not a mestra
file; `mkfiles.py` builds the conforming version of the same shape.

    ceiling.py reproduce OUTDIR      the ceiling under each mode
    ceiling.py stack OUTDIR          the C error stack of the failure
    ceiling.py sizes OUTDIR          REFERENCE_LIST bytes against N

Modes, which are the property calls under test:

    default   h5py defaults: H5Pset_libver_bounds is left alone, so
              the low bound is earliest and objects get version 1
              object headers.
    v18       H5Pset_libver_bounds(fapl, H5F_LIBVER_V18, LATEST)
    latest    H5Pset_libver_bounds(fapl, H5F_LIBVER_LATEST, LATEST)
    dense     default bounds, but H5Pset_attr_phase_change(dcpl, 0, 0)
              on the scale dataset alone.
    track     default bounds, but H5Pset_attr_creation_order(dcpl,
              H5P_CRT_ORDER_TRACKED) on the scale dataset alone.
"""

from __future__ import annotations

import os
import sys

import h5py
import numpy as np

MODES = ("default", "v18", "latest", "dense", "track")

SCALE_NAME = ("This is a netCDF dimension but not a netCDF variable."
              "%10d")


def fapl_for(mode):
    """The file access property list, or None for the library default."""
    if mode in ("default", "dense", "track"):
        return None
    fapl = h5py.h5p.create(h5py.h5p.FILE_ACCESS)
    if mode == "v18":
        fapl.set_libver_bounds(h5py.h5f.LIBVER_V18, h5py.h5f.LIBVER_LATEST)
    elif mode == "latest":
        fapl.set_libver_bounds(h5py.h5f.LIBVER_LATEST,
                               h5py.h5f.LIBVER_LATEST)
    else:
        raise ValueError(mode)
    return fapl


def open_new(path, mode):
    fapl = fapl_for(mode)
    if fapl is None:
        return h5py.File(path, "w")
    fid = h5py.h5f.create(path.encode(), h5py.h5f.ACC_TRUNC, fapl=fapl)
    return h5py.File(fid)


def make_scale(f, rows, mode, name="row"):
    """The `row` dimension scale of section 21, unlimited, chunk 1."""
    dcpl = h5py.h5p.create(h5py.h5p.DATASET_CREATE)
    dcpl.set_chunk((1,))
    if mode == "dense":
        # H5Pset_attr_phase_change: no compact attribute storage at
        # all, so every attribute of this dataset goes to the fractal
        # heap.  This is the one call that lifts the ceiling.
        dcpl.set_attr_phase_change(0, 0)
    elif mode == "track":
        dcpl.set_attr_creation_order(h5py.h5p.CRT_ORDER_TRACKED)
    space = h5py.h5s.create_simple((rows,), (h5py.h5s.UNLIMITED,))
    dsid = h5py.h5d.create(f.id, name.encode(),
                           h5py.h5t.IEEE_F32BE, space, dcpl=dcpl)
    ds = h5py.Dataset(dsid)
    ds.attrs.create("CLASS", b"DIMENSION_SCALE",
                    dtype=h5py.string_dtype("ascii", 16))
    ds.attrs.create("NAME", (SCALE_NAME % rows).encode(),
                    dtype=h5py.string_dtype("ascii", 64))
    return ds


def attach_n(path, n, mode, rows=2, stop_on_error=True):
    """Write N row-dimensioned datasets sharing one scale.

    Returns (attached, message).  `attached` is how many attachments
    the library accepted.
    """
    f = open_new(path, mode)
    scale = make_scale(f, rows, mode)
    values = np.zeros(rows, dtype="float64")
    attached = 0
    message = ""
    try:
        for i in range(n):
            d = f.create_dataset("v%06d" % i, data=values,
                                 maxshape=(None,), chunks=(rows,),
                                 track_times=False)
            d.dims[0].attach_scale(scale)
            attached += 1
    except Exception as exc:                       # noqa: BLE001
        message = "%s: %s" % (type(exc).__name__, str(exc).strip())
        if not stop_on_error:
            raise
    f.close()
    return attached, message


def reference_list_bytes(path):
    """The on-disk size of the scale's REFERENCE_LIST, in bytes."""
    with h5py.File(path, "r") as f:
        aid = h5py.h5a.open(f["row"].id, b"REFERENCE_LIST")
        return aid.get_storage_size(), aid.get_type().get_size()


def cmd_reproduce(outdir):
    counts = (1000, 4000, 4085, 4086, 8000)
    print("%-8s %6s %9s %9s  %s" % ("mode", "asked", "attached", "bytes",
                                    "outcome"))
    for mode in MODES:
        for n in counts:
            path = os.path.join(outdir, "ceil_%s_%d.h5" % (mode, n))
            got, msg = attach_n(path, n, mode)
            try:
                size, esize = reference_list_bytes(path)
            except Exception:                      # noqa: BLE001
                size, esize = -1, -1
            outcome = "ok" if got == n else msg[:70]
            print("%-8s %6d %9d %9d  %s" % (mode, n, got, size, outcome))
            sys.stdout.flush()
            if got == n and n >= 4086:
                # keep the interesting ones, drop the rest
                continue
            if got == n:
                os.unlink(path)


def cmd_stack(outdir):
    """The same failure with the HDF5 C error stack left visible."""
    import h5py._errors as errors
    errors.unsilence_errors()
    path = os.path.join(outdir, "stack.h5")
    try:
        attach_n(path, 4200, "default", stop_on_error=False)
    except Exception as exc:                       # noqa: BLE001
        sys.stderr.flush()
        print("\npython saw: %s: %s" % (type(exc).__name__, exc))
    errors.silence_errors()


def cmd_sizes(outdir):
    """How REFERENCE_LIST grows, and where 64 KiB lands."""
    print("%8s %10s %10s" % ("attached", "elem", "bytes"))
    for n in (1, 2, 1000, 4000, 4084, 4085):
        path = os.path.join(outdir, "size_%d.h5" % n)
        got, msg = attach_n(path, n, "default")
        size, esize = reference_list_bytes(path)
        print("%8d %10d %10d" % (got, esize, size))
        os.unlink(path)


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    cmd, outdir = argv[1], argv[2]
    os.makedirs(outdir, exist_ok=True)
    {"reproduce": cmd_reproduce, "stack": cmd_stack,
     "sizes": cmd_sizes}[cmd](outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
