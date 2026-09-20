"""Check the committed corpus against a fresh run of the generator.

    python check.py [corpus_directory]

For every case it regenerates case.mes and expected.json into a
temporary directory and compares them with the committed copy: byte
for byte first, and, when the bytes differ, by the structural
equality rule of SPEC.md section 30, which is the normative
comparison because the HDF5 library decides the superblock and the
object header layout.

It then opens every case that must validate cleanly with netCDF4 and
with h5netcdf and checks that each variable's dimension names are the
ones the file's own dimension scales give it, which is the check that
catches a reader taking a dimension name from the NAME attribute
instead of the link name.

One line per case; the exit status is non-zero if anything differs
or fails to open.
"""

import json
import os
import shutil
import sys
import tempfile

import h5py
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate  # noqa: E402

# Section 18: written by the HDF5 dimension scale machinery and by
# netCDF-C, no part of this format, and ignored wherever they appear.
MACHINERY = frozenset([
    "CLASS", "NAME", "DIMENSION_LIST", "REFERENCE_LIST",
    "DIMENSION_LABELS", "_Netcdf4Dimid", "_Netcdf4Coordinates",
    "_nc3_strict", "_NCProperties"])


# ----------------------------------------------- structural equality

def type_signature(dset):
    """The dtype including byte order and, for a string, its
    character set, its padding and its size."""
    t = dset.id.get_type()
    if isinstance(t, h5py.h5t.TypeStringID):
        return "string(size=%d,cset=%d,pad=%d)" % (
            t.get_size(), t.get_cset(), t.get_strpad())
    return "%s/%s" % (dset.dtype.str, t.get_order())


def attr_signature(obj, name):
    a = obj.attrs.get_id(name)
    t = a.get_type()
    if isinstance(t, h5py.h5t.TypeStringID):
        kind = "string(size=%s,cset=%d,pad=%d)" % (
            "vlen" if t.is_variable_str() else t.get_size(),
            t.get_cset(), t.get_strpad())
    else:
        kind = str(a.dtype.str)
    value = obj.attrs[name]
    if isinstance(value, np.ndarray):
        value = value.tolist()
    if isinstance(value, bytes):
        value = repr(value)
    return "%s=%r" % (kind, value)


def filters(dset):
    out = []
    if dset.shuffle:
        out.append("shuffle")
    if dset.compression is not None:
        out.append("%s:%s" % (dset.compression, dset.compression_opts))
    if dset.fletcher32:
        out.append("fletcher32")
    return ",".join(out)


def scale_names(dset):
    """The link name of each dimension scale attached to each axis."""
    names = []
    for dim in dset.dims:
        axis = []
        for i in range(len(dim)):
            axis.append(dim[i].name.rsplit("/", 1)[-1])
        names.append(tuple(axis))
    return names


def walk(f):
    paths = {}

    def visit(name, obj):
        paths["/" + name] = obj
    f.visititems(visit)
    paths["/"] = f
    return paths


def bits_equal(a, b):
    """Element-by-element equality with floats compared as bits, so
    that NaN equals NaN and the two zeros stay apart."""
    a = np.asarray(a)
    b = np.asarray(b)
    if a.shape != b.shape or a.dtype != b.dtype:
        return False
    if a.dtype.kind == "f":
        return np.array_equal(a.view("u%d" % a.dtype.itemsize),
                              b.view("u%d" % b.dtype.itemsize))
    return np.array_equal(a, b)


def structural_diff(path_a, path_b):
    """The differences between two files under the rule of section
    30, as a list of one-line strings."""
    out = []
    with h5py.File(path_a, "r") as fa, h5py.File(path_b, "r") as fb:
        a, b = walk(fa), walk(fb)
        for p in sorted(set(a) - set(b)):
            out.append("only in the committed file: %s" % p)
        for p in sorted(set(b) - set(a)):
            out.append("only in the fresh file: %s" % p)
        for p in sorted(set(a) & set(b)):
            oa, ob = a[p], b[p]
            if isinstance(oa, h5py.Dataset) != isinstance(
                    ob, h5py.Dataset):
                out.append("%s: group in one file, dataset in the "
                           "other" % p)
                continue
            na = set(oa.attrs) - MACHINERY
            nb = set(ob.attrs) - MACHINERY
            for name in sorted(na ^ nb):
                out.append("%s: attribute %s on one side only"
                           % (p, name))
            for name in sorted(na & nb):
                sa = attr_signature(oa, name)
                sb = attr_signature(ob, name)
                if sa != sb:
                    out.append("%s: attribute %s is %s and %s"
                               % (p, name, sa, sb))
            if not isinstance(oa, h5py.Dataset):
                continue
            for what, va, vb in (
                    ("dtype", type_signature(oa), type_signature(ob)),
                    ("shape", oa.shape, ob.shape),
                    ("maxshape", oa.maxshape, ob.maxshape),
                    ("chunks", oa.chunks, ob.chunks),
                    ("filters", filters(oa), filters(ob)),
                    ("dimensions", scale_names(oa), scale_names(ob))):
                if va != vb:
                    out.append("%s: %s is %r and %r"
                               % (p, what, va, vb))
            if oa.shape == ob.shape and oa.dtype == ob.dtype:
                if not bits_equal(oa[()], ob[()]):
                    out.append("%s: contents differ" % p)
    return out


# ------------------------------------------------ the netCDF readers

def netcdf_checks(path):
    """Open the file with two netCDF-4 readers that share no code and
    confirm that every variable's dimension names are the link names
    of the scales attached to it."""
    problems = []
    with h5py.File(path, "r") as f:
        wanted = {}

        def visit(name, obj):
            if isinstance(obj, h5py.Dataset) and not obj.attrs.get(
                    "CLASS", b"") == b"DIMENSION_SCALE":
                wanted["/" + name] = [n[0] if n else None
                                      for n in scale_names(obj)]
        f.visititems(visit)

    try:
        import netCDF4
    except ImportError:                                 # pragma: no cover
        return ["netCDF4 is not installed"]
    try:
        ds = netCDF4.Dataset(path, "r")
    except Exception as exc:
        return ["netCDF4 could not open the file: %s" % exc]
    try:
        seen = {}

        def descend(group):
            for name, var in group.variables.items():
                seen[group.path.rstrip("/") + "/" + name] = \
                    list(var.dimensions)
            for sub in group.groups.values():
                descend(sub)
        descend(ds)
        for p, dims in sorted(wanted.items()):
            if p not in seen:
                problems.append("netCDF4 does not expose %s" % p)
            elif seen[p] != dims:
                problems.append("netCDF4 gives %s the dimensions %r, "
                                "the file says %r" % (p, seen[p], dims))
    finally:
        ds.close()

    try:
        import h5netcdf
    except ImportError:                                 # pragma: no cover
        return problems + ["h5netcdf is not installed"]
    try:
        hf = h5netcdf.File(path, "r")
    except Exception as exc:
        return problems + ["h5netcdf could not open the file: %s" % exc]
    try:
        seen = {}

        def descend2(group, prefix):
            for name, var in group.variables.items():
                seen[prefix + "/" + name] = list(var.dimensions)
            for name, sub in group.groups.items():
                descend2(sub, prefix + "/" + name)
        descend2(hf, "")
        for p, dims in sorted(wanted.items()):
            if p not in seen:
                problems.append("h5netcdf does not expose %s" % p)
            else:
                got = [d.rsplit("/", 1)[-1] for d in seen[p]]
                if got != dims:
                    problems.append(
                        "h5netcdf gives %s the dimensions %r, the "
                        "file says %r" % (p, got, dims))
    finally:
        hf.close()
    return problems


# -------------------------------------------------------------- main

def main(argv):
    root = (argv[1] if len(argv) > 1
            else os.path.dirname(os.path.abspath(__file__)))
    cases_dir = os.path.join(root, "cases")
    tmp = tempfile.mkdtemp(prefix="mestra-corpus-")
    failures = 0
    try:
        fresh_cases = os.path.join(tmp, "cases")
        quiet = sys.stdout
        sys.stdout = open(os.devnull, "w")
        try:
            generate.main(["generate.py", tmp])
        finally:
            sys.stdout.close()
            sys.stdout = quiet

        committed = sorted(os.listdir(cases_dir)) if os.path.isdir(
            cases_dir) else []
        committed = [c for c in committed
                     if os.path.isdir(os.path.join(cases_dir, c))]
        expected_names = sorted(generate.CASES)
        for name in sorted(set(committed) - set(expected_names)):
            print("%-28s FAIL  committed but not produced by the "
                  "generator" % name)
            failures += 1

        for name in expected_names:
            notes = []
            a = os.path.join(cases_dir, name, "case.mes")
            b = os.path.join(fresh_cases, name, "case.mes")
            aj = os.path.join(cases_dir, name, "expected.json")
            bj = os.path.join(fresh_cases, name, "expected.json")
            if not os.path.exists(a):
                print("%-28s FAIL  missing from the corpus" % name)
                failures += 1
                continue
            with open(aj, "rb") as fh:
                ja = fh.read()
            with open(bj, "rb") as fh:
                jb = fh.read()
            if ja != jb:
                notes.append("expected.json differs")
            with open(a, "rb") as fh:
                ba = fh.read()
            with open(b, "rb") as fh:
                bb = fh.read()
            if ba == bb:
                how = "bytes equal"
            else:
                diffs = structural_diff(a, b)
                if diffs:
                    notes.extend(diffs[:5])
                    how = "%d structural differences" % len(diffs)
                else:
                    how = "structurally equal, bytes differ"
            exp = json.loads(ja.decode("utf-8"))
            if not exp["validator"]["errors"]:
                notes.extend(netcdf_checks(a))
            if notes:
                failures += 1
                print("%-28s FAIL  %s" % (name, how))
                for note in notes:
                    print("%-28s       %s" % ("", note))
            else:
                print("%-28s ok    %s" % (name, how))

        mf = os.path.join(root, "manifest.json")
        with open(mf, "rb") as fh:
            ma = fh.read()
        with open(os.path.join(tmp, "manifest.json"), "rb") as fh:
            mb = fh.read()
        if ma != mb:
            failures += 1
            print("%-28s FAIL  differs from the generator's output"
                  % "manifest.json")
        else:
            print("%-28s ok    bytes equal" % "manifest.json")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("%d case(s), %d failure(s)" % (len(generate.CASES), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
