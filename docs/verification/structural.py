"""Structural equality of two mestra files, per SPEC.md section 30.

Written for the Phase 3 verification and deliberately independent: it
uses h5py and the HDF5 low-level API only, and shares no code with any
of the four implementations or with vectors/check.py.

  python docs/verification/structural.py A.mes B.mes

Prints one line per difference and exits non-zero when there is one.
"""

from __future__ import annotations

import sys

import h5py
import numpy as np

# Section 18: attributes written by the dimension scale machinery and by
# netCDF-C are not part of the format and are excluded from comparison.
MACHINERY = frozenset(
    {
        "CLASS",
        "NAME",
        "DIMENSION_LIST",
        "REFERENCE_LIST",
        "DIMENSION_LABELS",
        "_Netcdf4Dimid",
        "_Netcdf4Coordinates",
        "_nc3_strict",
        "_NCProperties",
    }
)

MAX_DEPTH = 64


def type_signature(tid):
    """A canonical description of an HDF5 datatype.

    Covers what section 30 asks for: the dtype including byte order,
    character set and padding.
    """
    cls = tid.get_class()
    if cls == h5py.h5t.STRING:
        return (
            "string",
            int(tid.get_size()),
            int(tid.get_cset()),
            int(tid.get_strpad()),
            bool(tid.is_variable_str()),
        )
    if cls == h5py.h5t.INTEGER:
        return ("int", int(tid.get_size()), int(tid.get_order()), int(tid.get_sign()))
    if cls == h5py.h5t.FLOAT:
        return ("float", int(tid.get_size()), int(tid.get_order()))
    return ("class%d" % int(cls), int(tid.get_size()))


def raw_bytes(values, dtype):
    """The exact stored bytes of an array, so floats compare as bits."""
    arr = np.asarray(values, dtype=dtype)
    return arr.tobytes()


def attribute_signature(obj, name):
    aid = h5py.h5a.open(obj.id, name.encode("utf-8"))
    tid = aid.get_type()
    sid = aid.get_space()
    extent = (
        int(sid.get_simple_extent_type()),
        tuple(int(x) for x in sid.get_simple_extent_dims() or ()),
    )
    value = obj.attrs.get(name)
    if tid.get_class() == h5py.h5t.STRING and tid.is_variable_str():
        # Not legal in this format, but a comparison must survive one.
        payload = repr(value)
    else:
        arr = np.asarray(value)
        if arr.dtype.kind in "SU":
            payload = arr.astype(arr.dtype.newbyteorder("=")).tobytes()
        else:
            payload = arr.tobytes()
    return (type_signature(tid), extent, payload)


def filter_signature(dcpl):
    out = []
    for i in range(dcpl.get_nfilters()):
        code, flags, cd, _name = dcpl.get_filter(i)
        out.append((int(code), int(flags), tuple(int(v) for v in cd)))
    return tuple(out)


def walk(path):
    """Bounded, hard-link-only walk. Returns objects, scales, problems.

    objects: path -> ("group"|"dataset", h5py object)
    scales:  object address -> link name of a dimension scale dataset
    """
    objects = {}
    scales = {}
    problems = []
    f = h5py.File(path, "r")

    def address(obj):
        info = h5py.h5o.get_info(obj.id)
        try:
            return bytes(info.token)
        except AttributeError:
            return int(info.addr)

    def visit(group, prefix, depth):
        if depth > MAX_DEPTH:
            problems.append("%s: deeper than the depth cap" % prefix)
            return
        for name in sorted(group.keys()):
            link = group.get(name, getlink=True)
            if not isinstance(link, h5py.HardLink):
                problems.append("%s/%s: not a hard link" % (prefix, name))
                continue
            child = group[name]
            here = "%s/%s" % (prefix, name)
            if isinstance(child, h5py.Group):
                objects[here] = ("group", child)
                visit(child, here, depth + 1)
            else:
                objects[here] = ("dataset", child)
                cls = child.attrs.get("CLASS")
                if cls is not None and bytes(np.asarray(cls).tobytes()).rstrip(
                    b"\x00"
                ) == b"DIMENSION_SCALE":
                    scales[address(child)] = name

    objects["/"] = ("group", f)
    visit(f, "", 0)
    return f, objects, scales, problems


def attached_scale_names(dset, scales):
    """The link name of the scale attached to each axis, by address.

    Section 21 forbids asking the library for the scale object's path.
    """
    names = []
    for axis in range(len(dset.shape)):
        found = []

        def collect(dsid, found=found):
            obj = h5py.Dataset(dsid)
            info = h5py.h5o.get_info(obj.id)
            try:
                key = bytes(info.token)
            except AttributeError:
                key = int(info.addr)
            found.append(scales.get(key, "<unmapped>"))
            return None

        try:
            h5py.h5ds.iterate(dset.id, axis, collect, 0)
        except Exception as exc:  # pragma: no cover - malformed input
            found.append("<error:%s>" % type(exc).__name__)
        names.append(tuple(found))
    return tuple(names)


def compare(path_a, path_b):
    fa, oa, sa, pa = walk(path_a)
    fb, ob, sb, pb = walk(path_b)
    diffs = ["A %s" % p for p in pa] + ["B %s" % p for p in pb]
    try:
        only_a = sorted(set(oa) - set(ob))
        only_b = sorted(set(ob) - set(oa))
        for p in only_a:
            diffs.append("path only in A: %s" % p)
        for p in only_b:
            diffs.append("path only in B: %s" % p)

        for p in sorted(set(oa) & set(ob)):
            kind_a, obj_a = oa[p]
            kind_b, obj_b = ob[p]
            if kind_a != kind_b:
                diffs.append("%s: kind %s vs %s" % (p, kind_a, kind_b))
                continue

            names_a = sorted(n for n in obj_a.attrs if n not in MACHINERY)
            names_b = sorted(n for n in obj_b.attrs if n not in MACHINERY)
            if names_a != names_b:
                diffs.append(
                    "%s: attribute names %s vs %s" % (p, names_a, names_b)
                )
            for n in sorted(set(names_a) & set(names_b)):
                siga = attribute_signature(obj_a, n)
                sigb = attribute_signature(obj_b, n)
                if siga != sigb:
                    diffs.append(
                        "%s@%s: attribute %r vs %r" % (p, n, siga, sigb)
                    )

            if kind_a != "dataset":
                continue

            ta = obj_a.id.get_type()
            tb = obj_b.id.get_type()
            if type_signature(ta) != type_signature(tb):
                diffs.append(
                    "%s: dtype %r vs %r"
                    % (p, type_signature(ta), type_signature(tb))
                )
                continue
            if obj_a.shape != obj_b.shape:
                diffs.append("%s: shape %s vs %s" % (p, obj_a.shape, obj_b.shape))
                continue
            ma = obj_a.id.get_space().get_simple_extent_dims(True)
            mb = obj_b.id.get_space().get_simple_extent_dims(True)
            if ma != mb:
                diffs.append("%s: maxshape %s vs %s" % (p, ma, mb))
            if obj_a.chunks != obj_b.chunks:
                diffs.append("%s: chunks %s vs %s" % (p, obj_a.chunks, obj_b.chunks))
            da = obj_a.id.get_create_plist()
            db = obj_b.id.get_create_plist()
            if da.get_layout() != db.get_layout():
                diffs.append(
                    "%s: layout %s vs %s" % (p, da.get_layout(), db.get_layout())
                )
            if filter_signature(da) != filter_signature(db):
                diffs.append(
                    "%s: filters %r vs %r"
                    % (p, filter_signature(da), filter_signature(db))
                )

            if 0 not in obj_a.shape:
                va = obj_a[()]
                vb = obj_b[()]
                ba = raw_bytes(va, obj_a.dtype)
                bb = raw_bytes(vb, obj_b.dtype)
                if ba != bb:
                    diffs.append("%s: contents differ" % p)

            na = attached_scale_names(obj_a, sa)
            nb = attached_scale_names(obj_b, sb)
            if na != nb:
                diffs.append("%s: attached scales %r vs %r" % (p, na, nb))
    finally:
        fa.close()
        fb.close()
    return diffs


def fill_value_set(path):
    """Section 19: a writer must not set an HDF5 fill value.

    Reported separately; it is not part of the section 30 comparison.
    """
    out = []
    f, objects, _scales, _problems = walk(path)
    try:
        for p, (kind, obj) in sorted(objects.items()):
            if kind != "dataset":
                continue
            dcpl = obj.id.get_create_plist()
            if dcpl.fill_value_defined() == h5py.h5d.FILL_VALUE_USER_DEFINED:
                out.append(p)
    finally:
        f.close()
    return out


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    diffs = compare(argv[1], argv[2])
    for d in diffs:
        print(d)
    if diffs:
        print("%d difference(s)" % len(diffs))
        return 1
    print("structurally equal")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
