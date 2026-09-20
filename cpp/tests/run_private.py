#!/usr/bin/env python3
"""A round trip of a file carrying /private, compared structurally.

Sections 12 and 29 forbid a reader to interpret /private and say
nothing against copying it, so a file that carries one must come back
out of `mestra-cli roundtrip` with that group intact: the same objects,
the same dtypes -- including the ones section 18 forbids in the public
part, which is the point -- the same chunks, the same filters, the same
attributes and the same dimension scales attached by name.

    python3 run_private.py --cli ../build/mestra-cli --vectors ../../vectors

The comparison is run_corpus.py's, which is section 30's structural
equality; nothing here is a mestra implementation.  It needs h5py and
skips with a note when h5py is not importable.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_corpus import structural_diff          # noqa: E402

try:
    import h5py
    import numpy
except ImportError:                                   # pragma: no cover
    h5py = None
    numpy = None

DIM_NAME = "This is a netCDF dimension but not a netCDF variable."


def sattr(obj, name, text, cset="utf-8", length=None):
    raw = text.encode("utf-8")
    size = length if length is not None else max(1, len(raw))
    obj.attrs.create(name, raw.ljust(size, b"\0"),
                     dtype=h5py.string_dtype(encoding=cset, length=size))


def scale(group, name, length):
    d = group.create_dataset(name, shape=(length,), dtype=">f4",
                             chunks=(length,), track_times=False)
    sattr(d, "CLASS", "DIMENSION_SCALE")
    sattr(d, "NAME", "%s%10d" % (DIM_NAME, length))
    return d


def build(source, path):
    """A valid file with a private group worth losing."""
    shutil.copy(source, path)
    with h5py.File(path, "r+") as f:
        private = f.create_group("private")
        # A vlen string attribute and a float attribute: both are
        # encodings section 18 forbids on a public object, and neither
        # is any of this reader's business here.
        private.attrs.create("ticket", "XYZ-1",
                             dtype=h5py.string_dtype("utf-8"))
        private.attrs.create("attempts", numpy.int32(3))
        sattr(private, "stage", "post")

        history = private.create_group("history")
        sattr(history, "tool", "a solver 3.1")
        # A scale of its own, and a dataset attached to it.
        idx = scale(history, "sample", 4)
        stamps = history.create_dataset(
            "stamps", data=numpy.arange(4.0), dtype="<f8", chunks=(2,),
            compression="gzip", compression_opts=9, shuffle=True,
            track_times=False)
        stamps.dims[0].attach_scale(idx)

        # Two axes, two scales, and a dtype the public rules do not
        # allow anywhere (int16, big endian).
        wide = scale(history, "pass", 2)
        grid = history.create_dataset(
            "grid", data=numpy.arange(8, dtype=">i2").reshape(2, 4),
            track_times=False)
        grid.dims[0].attach_scale(wide)
        grid.dims[1].attach_scale(idx)

        # A fixed-length string dataset that is ASCII and NUL
        # terminated, which section 18 forbids on a public object.
        labels = private.create_dataset(
            "labels", shape=(2,), track_times=False,
            dtype=h5py.string_dtype(encoding="ascii", length=6))
        labels[...] = [b"first", b"second"[:6]]

        # A dataset inside /private attached to the file's own `row`
        # scale, which the copy must find outside the group it copied.
        rows = f["/row"].shape[0]
        perrow = private.create_dataset(
            "perrow", data=numpy.zeros(rows), maxshape=(None,),
            chunks=(max(1, rows),), track_times=False)
        perrow.dims[0].attach_scale(f["/row"])

        # A subgroup holding nothing, which is still an object path.
        private.create_group("empty")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--vectors", required=True)
    arguments = parser.parse_args(argv[1:])
    if h5py is None:
        print("h5py is not importable; the /private round trip is skipped")
        return 0

    source_case = os.path.join(arguments.vectors, "cases", "mesh_two_rows",
                               "case.mes")
    if not os.path.exists(source_case):
        print("no mesh_two_rows case under %s" % arguments.vectors)
        return 1

    failures = []
    with tempfile.TemporaryDirectory() as scratch:
        source = os.path.join(scratch, "source.mes")
        written = os.path.join(scratch, "written.mes")
        build(source_case, source)

        check = subprocess.run([arguments.cli, "validate", source],
                               capture_output=True, text=True)
        if check.returncode != 0:
            failures.append("the source file does not validate:\n" +
                            check.stdout + check.stderr)
        trip = subprocess.run([arguments.cli, "roundtrip", source, written],
                              capture_output=True, text=True)
        if trip.returncode != 0:
            failures.append("roundtrip failed:\n" + trip.stdout + trip.stderr)
        elif not os.path.exists(written):
            failures.append("roundtrip wrote no file")
        else:
            failures.extend(structural_diff(source, written))

    if failures:
        print("the /private round trip is not structurally equal:")
        for problem in failures:
            print("  " + problem)
        return 1
    print("the /private round trip is structurally equal, group and all")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
