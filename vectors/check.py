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

The hostile subset of section 30 is compared by bytes, except for
the two deep files, which are not committed: they are generated into
place if missing and compared structurally, because two people's
copies come from two libhdf5 versions. Nothing here opens a hostile
file with a netCDF reader, and every walk is depth capped and
resolves dimension scales by address, which is what section 29 and
section 21 require of a reader facing a file it did not write.

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


MAX_DEPTH = 64


def is_scale(d):
    return isinstance(d, h5py.Dataset) and \
        d.attrs.get("CLASS", b"") in (b"DIMENSION_SCALE",
                                      "DIMENSION_SCALE")


def scale_names(dset, by_addr):
    """The link name of each dimension scale attached to each axis,
    found by object address.

    Never `dim[i].name`. Resolving an attached scale's path makes
    HDF5 search the group hierarchy, and on a file with thirty
    thousand nested groups that search runs off the stack and takes
    the process with it (section 21). Dereferencing the scale and
    reading its address is safe; the name comes from the map the walk
    builds."""
    names = []
    for dim in dset.dims:
        axis = []
        for i in range(len(dim)):
            try:
                addr = h5py.h5o.get_info(dim[i].id).addr
            except Exception:
                axis.append(None)
                continue
            axis.append(by_addr.get(addr, "<outside the walk>"))
        names.append(tuple(axis))
    return names


def walk(f):
    """Iterative, depth capped and hard links only, as section 29
    requires of any reader facing a file it did not write. Returns
    the objects, a map from scale address to link name, and whether
    the cap was reached."""
    paths = {"/": f}
    by_addr = {}
    capped = False
    stack = [("", f, 0)]
    while stack:
        prefix, g, depth = stack.pop()
        if depth >= MAX_DEPTH:
            capped = True
            continue
        for name in sorted(g):
            path = prefix + "/" + name
            if not isinstance(g.get(name, getlink=True), h5py.HardLink):
                paths[path] = "a link that is not a hard link"
                continue
            obj = g[name]
            paths[path] = obj
            if is_scale(obj):
                by_addr[h5py.h5o.get_info(obj.id).addr] = name
            if isinstance(obj, h5py.Group):
                stack.append((path, obj, depth + 1))
    return paths, by_addr, capped


def chain_depth(f, root):
    """How far the chain of groups named `g` runs below `root`. The
    handles are released as it goes; holding thirty thousand open
    groups is what makes a naive walk of these files crawl."""
    cur = f[root]
    depth = 0
    while depth <= 40000 and isinstance(cur, h5py.Group) and "g" in cur:
        cur = cur["g"]
        depth += 1
    return depth


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


def structural_diff(path_a, path_b, chain=None):
    """The differences between two files under the rule of section
    30, as a list of one-line strings. With `chain` the length of the
    group chain below that path is compared too, which is the one
    thing the depth cap would otherwise hide."""
    out = []
    with h5py.File(path_a, "r") as fa, h5py.File(path_b, "r") as fb:
        a, aa, acap = walk(fa)
        b, ba, bcap = walk(fb)
        if chain is not None:
            da, db = chain_depth(fa, chain), chain_depth(fb, chain)
            if da != db:
                out.append("the chain below /%s is %d deep and %d deep"
                           % (chain, da, db))
        for p in sorted(set(a) - set(b)):
            out.append("only in the committed file: %s" % p)
        for p in sorted(set(b) - set(a)):
            out.append("only in the fresh file: %s" % p)
        for p in sorted(set(a) & set(b)):
            oa, ob = a[p], b[p]
            if not isinstance(oa, h5py.Dataset) and \
                    not isinstance(ob, h5py.Dataset) and \
                    (isinstance(oa, str) or isinstance(ob, str)):
                if oa != ob:
                    out.append("%s: %r and %r" % (p, oa, ob))
                continue
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
                    ("dimensions", scale_names(oa, aa),
                     scale_names(ob, ba))):
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
        objs, by_addr, _capped = walk(f)
        for p, obj in objs.items():
            if isinstance(obj, h5py.Dataset) and not is_scale(obj):
                wanted[p] = [n[0] if n else None
                             for n in scale_names(obj, by_addr)]

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
            generate.main(["generate.py", tmp, "--hostile-deep"])
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

        hostile_dir = os.path.join(root, "hostile")
        fresh_hostile = os.path.join(tmp, "hostile")
        have = sorted(os.listdir(hostile_dir)) if os.path.isdir(
            hostile_dir) else []
        have = [c for c in have
                if os.path.isdir(os.path.join(hostile_dir, c))]
        for name in sorted(set(have) - set(generate.HOSTILE)):
            print("%-28s FAIL  committed but not produced by the "
                  "generator" % name)
            failures += 1
        for name in sorted(generate.DEEP):
            a = os.path.join(hostile_dir, name, "case.mes")
            if not os.path.exists(a):
                quiet = sys.stdout
                sys.stdout = open(os.devnull, "w")
                try:
                    generate.write_case(hostile_dir, name,
                                        generate.HOSTILE[name])
                finally:
                    sys.stdout.close()
                    sys.stdout = quiet
                print("%-28s generated, it is not committed" % name)

        for name in sorted(generate.HOSTILE):
            notes = []
            a = os.path.join(hostile_dir, name, "case.mes")
            b = os.path.join(fresh_hostile, name, "case.mes")
            aj = os.path.join(hostile_dir, name, "expected.json")
            bj = os.path.join(fresh_hostile, name, "expected.json")
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
            if name in generate.DEEP:
                # Generated on demand, so two people's copies come
                # from two libhdf5 versions and byte identity is not
                # the comparison (section 30). The walk below is
                # depth capped and the chain is measured separately.
                diffs = structural_diff(a, b, generate.DEEP[name])
                if diffs:
                    notes.extend(diffs[:5])
                    how = "%d structural differences" % len(diffs)
                else:
                    how = "structurally equal (%d MB, generated)" % (
                        len(ba) // 1048576)
            elif ba == bb:
                how = "bytes equal (%d kB)" % (len(ba) // 1024)
            else:
                how = "bytes differ"
                notes.append(
                    "%d of %d bytes differ"
                    % (sum(1 for x, y in zip(ba, bb) if x != y),
                       max(len(ba), len(bb))))
            exp = json.loads(ja.decode("utf-8"))
            for field, want in (("allow_extra", True),
                                ("timeout_seconds", 10)):
                if exp.get(field) != want:
                    notes.append("%s is %r, section 30 says %r"
                                 % (field, exp.get(field), want))
            if not exp.get("required_errors"):
                notes.append("required_errors is empty")
            if notes:
                failures += 1
                print("%-28s FAIL  %s" % ("hostile/" + name, how))
                for note in notes:
                    print("%-28s       %s" % ("", note))
            else:
                print("%-28s ok    %s" % ("hostile/" + name, how))

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

    print("%d case(s), %d hostile file(s), %d failure(s)"
          % (len(generate.CASES), len(generate.HOSTILE), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
