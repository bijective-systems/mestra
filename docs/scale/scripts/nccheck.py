"""What netCDF-C does to a mestra file, and what it writes itself.

    nccheck.py NCCOPY CLI CASE.mes OUTDIR

Three measurements:

  1. a round trip of CASE.mes through `nccopy -k nc4`, reported as the
     differences that survive it, object by object;
  2. the properties netCDF-C sets on the files it creates, read back
     from the property lists of a file written with the netCDF4
     package;
  3. whether netCDF-C can write 8000 variables on one dimension, and
     what its dimension scale looks like when it has.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time

import h5py
import numpy as np

CSET = {0: "ascii", 1: "utf-8"}
PAD = {0: "nullterm", 1: "nullpad", 2: "spacepad"}


def str_kind(tid):
    try:
        return "%s %s size %d" % (CSET.get(tid.get_cset(), "?"),
                                  PAD.get(tid.get_strpad(), "?"),
                                  tid.get_size())
    except Exception:                              # noqa: BLE001
        return "not a string"


def attr_kinds(obj):
    out = {}
    for name in obj.attrs:
        aid = h5py.h5a.open(obj.id, name.encode())
        out[name] = (str_kind(aid.get_type()), aid.shape)
    return out


def describe(path):
    """Every object of a file, in the terms sections 18 and 19 use."""
    out = {}
    with h5py.File(path, "r") as f:
        out["/"] = {"attrs": attr_kinds(f)}

        def visit(name, obj):
            if isinstance(obj, h5py.Dataset):
                out["/" + name] = {
                    "dtype": str(obj.dtype), "shape": obj.shape,
                    "maxshape": obj.maxshape, "chunks": obj.chunks,
                    "attrs": attr_kinds(obj),
                    "class": obj.attrs.get("CLASS")}
            else:
                out["/" + name] = {"attrs": attr_kinds(obj)}

        f.visititems(visit)
    return out


def compare(a, b):
    lines = []
    for name in sorted(set(a) | set(b)):
        if name not in a:
            lines.append("  only in the copy: %s" % name)
            continue
        if name not in b:
            lines.append("  gone from the copy: %s" % name)
            continue
        x, y = a[name], b[name]
        for key in ("dtype", "shape", "maxshape", "chunks"):
            if x.get(key) != y.get(key):
                lines.append("  %s: %s %s -> %s"
                             % (name, key, x.get(key), y.get(key)))
        for attr in sorted(set(x["attrs"]) | set(y["attrs"])):
            if attr not in x["attrs"]:
                lines.append("  %s: attribute %s added" % (name, attr))
            elif attr not in y["attrs"]:
                lines.append("  %s: attribute %s gone" % (name, attr))
            elif x["attrs"][attr] != y["attrs"][attr]:
                lines.append("  %s: attribute %s %s -> %s"
                             % (name, attr, x["attrs"][attr],
                                y["attrs"][attr]))
    return lines


def round_trip(nccopy, cli, case, outdir):
    copy = os.path.join(outdir, "nccopy.mes")
    p = subprocess.run([nccopy, "-k", "nc4", case, copy],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print("nccopy failed: %s" % p.stderr.strip()[:200])
        return
    print("1. `nccopy -k nc4` on a golden case")
    for line in compare(describe(case), describe(copy)):
        print(line)
    out = subprocess.run([cli, "validate", copy], capture_output=True,
                         text=True).stdout.strip().splitlines()
    print("  the C++ validator on the copy: %s"
          % "; ".join(out[:4] + out[-1:]))


def own_properties(outdir):
    import netCDF4
    path = os.path.join(outdir, "nc_small.nc")
    d = netCDF4.Dataset(path, "w", format="NETCDF4")
    d.setncattr("format", "mestra/0")
    d.createDimension("row", None)
    v = d.createVariable("cl", "f8", ("row",))
    v.units = "1"
    v[:] = [1.0, 2.0]
    d.close()
    print("\n2. what netCDF-C sets on what it writes")
    with open(path, "rb") as fh:
        print("  superblock version %d" % fh.read(16)[8])
    with h5py.File(path, "r") as f:
        gcpl = f["/"].id.get_create_plist()
        print("  root group: link creation order %d, attribute "
              "creation order %d" % (gcpl.get_link_creation_order(),
                                     gcpl.get_attr_creation_order()))
        for name in ("row", "cl"):
            dcpl = f[name].id.get_create_plist()
            print("  %-4s attribute creation order %d, phase change "
                  "%s, times %d, chunks %s"
                  % (name, dcpl.get_attr_creation_order(),
                     dcpl.get_attr_phase_change(),
                     dcpl.get_obj_track_times(), f[name].chunks))
        print("  row scale: shape %s, max %s, dtype %s"
              % (f["row"].shape, f["row"].maxshape, f["row"].dtype))
        for obj, label in ((f, "/"), (f["cl"], "cl")):
            for name, kind in sorted(attr_kinds(obj).items()):
                print("  %-4s attribute %-20s %s" % (label, name, kind[0]))
    with open(path, "rb") as fh:
        blob = fh.read()
    print("  version 2 object headers: %d" % blob.count(b"OHDR"))


def many_variables(outdir, n=8000):
    import netCDF4
    path = os.path.join(outdir, "nc_many.nc")
    t = time.time()
    d = netCDF4.Dataset(path, "w", format="NETCDF4")
    d.createDimension("row", None)
    for i in range(n):
        d.createVariable("v%06d" % i, "f8", ("row",))
    d.variables["v000000"][:] = [1.0, 2.0]
    d.close()
    print("\n3. netCDF-C with %d variables on one dimension" % n)
    print("  written in %.1f s, %d bytes" % (time.time() - t,
                                             os.path.getsize(path)))
    with h5py.File(path, "r") as f:
        row = f["row"]
        aid = h5py.h5a.open(row.id, b"REFERENCE_LIST")
        print("  REFERENCE_LIST: %d entries, %d bytes on disk"
              % (aid.shape[0], aid.get_storage_size()))
        print("  the row scale's own length: %d, maximum %s"
              % (row.shape[0], row.maxshape[0]))
    with open(path, "rb") as fh:
        blob = fh.read()
    print("  version 2 object headers: %d, fractal heaps: %d"
          % (blob.count(b"OHDR"), blob.count(b"FRHP")))


def main(argv):
    nccopy, cli, case, outdir = argv[1:5]
    os.makedirs(outdir, exist_ok=True)
    round_trip(nccopy, cli, case, outdir)
    own_properties(outdir)
    many_variables(outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
