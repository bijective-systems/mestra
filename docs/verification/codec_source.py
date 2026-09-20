"""Build a file whose callable dictionary holds every leaf of s.17.

Written with h5py against sections 17, 18, 21 and 25 directly, so
that the source of the codec test comes from no implementation. It
starts from the corpus case `affine_zero_rows` and replaces its
callable with one of an unregistered type, so that every reader keeps
the dictionary whole rather than interpreting it.

  python docs/verification/codec_source.py OUT.mes REF.json
"""

from __future__ import annotations

import json
import shutil
import sys

import h5py
import numpy as np

DIM_NAME = "This is a netCDF dimension but not a netCDF variable."
CASE = "vectors/cases/affine_zero_rows/case.mes"


def sdtype(nbytes):
    return h5py.string_dtype(encoding="utf-8", length=max(1, nbytes))


def sattr(obj, name, value):
    raw = value.encode("utf-8")
    n = max(1, len(raw))
    obj.attrs.create(name, raw.ljust(n, b"\0"), dtype=sdtype(n))


def rattr(obj, name, raw):
    n = max(1, len(raw))
    obj.attrs.create(name, raw.ljust(n, b"\0"), dtype=sdtype(n))


def scale(group, name, length, unlimited=False):
    d = group.create_dataset(
        name, shape=(length,), dtype=">f4", track_times=False,
        maxshape=(None,) if unlimited else None,
        chunks=(1,) if unlimited else ((length,) if length else (1,)))
    sattr(d, "CLASS", "DIMENSION_SCALE")
    sattr(d, "NAME", "%s%10d" % (DIM_NAME, length))
    return d


def array(group, name, data):
    data = np.asarray(data)
    empty = 0 in data.shape
    d = group.create_dataset(
        name, shape=data.shape, dtype=data.dtype.newbyteorder("<"),
        data=data, track_times=False,
        maxshape=tuple(None if n == 0 else n for n in data.shape)
        if empty else None,
        chunks=(1,) * data.ndim if empty else None)
    for axis, length in enumerate(data.shape):
        s = scale(group, "mestra_%s_d%d" % (name, axis), length,
                  unlimited=(length == 0))
        d.dims[axis].attach_scale(s)
    return d


def strings(group, name, values, size=None):
    raw = [v.encode("utf-8") for v in values]
    n = size if size is not None else max([len(r) for r in raw] + [1])
    empty = len(raw) == 0
    d = group.create_dataset(
        name, shape=(len(raw),), dtype=sdtype(n),
        data=[r.ljust(n, b"\0") for r in raw] if raw else None,
        track_times=False,
        maxshape=(None,) if empty else None,
        chunks=(1,) if empty else None)
    s = scale(group, "mestra_%s_d0" % name, len(raw), unlimited=empty)
    d.dims[0].attach_scale(s)
    return d


def f64(x):
    return "%.17e" % float(x)


def build(out, ref_path):
    shutil.copy(CASE, out)
    reference = {}
    with h5py.File(out, "r+") as f:
        del f["callables"]["m1"]
        g = f.create_group("callables/m1")
        sattr(g, "type", "verify_all")
        sattr(g, "repr", "every leaf of section 17")

        # Scalars, one per attribute encoding of section 18. An
        # integer and a float that happen to be equal stay different.
        g.attrs.create("an_int", np.int64(7))
        g.attrs.create("a_float", np.float64(7.0))
        g.attrs.create("a_true", np.int8(1))
        g.attrs.create("a_false", np.int8(0))
        sattr(g, "a_string", "a plain ascii string")
        sattr(g, "an_empty_string", "")
        rattr(g, "a_null", b"\x00null")
        g.attrs.create("a_negative", np.int64(-9223372036854775807))
        g.attrs.create("a_tiny_float", np.float64(5e-324))

        # Arrays and lists.
        array(g, "floats_2d", np.array([[1.5, -2.5, 3.0],
                                        [4.25, 5.0, 6.125]]))
        array(g, "floats_3d", np.arange(24, dtype="<f8").reshape(2, 3, 4))
        array(g, "ints64_1d", np.array([1, 2, 3], dtype="<i8"))
        array(g, "ints32_2d", np.array([[10, 20], [30, 40]], dtype="<i4"))
        array(g, "bools_1d", np.array([1, 0, 1], dtype="<i1"))
        array(g, "nonfinite", np.array([np.nan, np.inf, -np.inf, 0.0]))
        array(g, "empty_f64", np.zeros((0,), dtype="<f8"))
        array(g, "empty_i64_2d", np.zeros((0, 3), dtype="<i8"))
        strings(g, "list_of_strings", ["mach", "alpha", "beta"])
        strings(g, "empty_strings", [], size=1)

        # A nested dictionary, and one that uses `type` and `repr` as
        # keys, which section 25 allows below the top level.
        n = g.create_group("nest")
        n.attrs.create("depth", np.int64(1))
        array(n, "values", np.array([0.5, 1.5], dtype="<f8"))
        d2 = n.create_group("deeper")
        sattr(d2, "type", "not the callable type")
        sattr(d2, "repr", "not the callable repr")
        d2.attrs.create("depth", np.int64(2))
        empty_group = g.create_group("an_empty_dict")
        del empty_group

    reference = {
        "t": "dict",
        "v": {
            "a_false": {"t": "bool", "v": False},
            "a_float": {"t": "f64", "v": f64(7.0)},
            "a_negative": {"t": "i64", "v": -9223372036854775807},
            "a_null": {"t": "null"},
            "a_string": {"t": "str", "v": "a plain ascii string"},
            "a_tiny_float": {"t": "f64", "v": f64(5e-324)},
            "a_true": {"t": "bool", "v": True},
            "an_empty_dict": {"t": "dict", "v": {}},
            "an_empty_string": {"t": "str", "v": ""},
            "an_int": {"t": "i64", "v": 7},
            "bools_1d": {"t": "array", "dtype": "bool", "shape": [3],
                         "data": [True, False, True]},
            "empty_f64": {"t": "array", "dtype": "float64", "shape": [0],
                          "data": []},
            "empty_i64_2d": {"t": "array", "dtype": "int64", "shape": [0, 3],
                             "data": []},
            "empty_strings": {"t": "strings", "shape": [0], "data": []},
            "floats_2d": {"t": "array", "dtype": "float64", "shape": [2, 3],
                          "data": [f64(x) for x in
                                   [1.5, -2.5, 3.0, 4.25, 5.0, 6.125]]},
            "floats_3d": {"t": "array", "dtype": "float64",
                          "shape": [2, 3, 4],
                          "data": [f64(x) for x in range(24)]},
            "ints32_2d": {"t": "array", "dtype": "int32", "shape": [2, 2],
                          "data": [10, 20, 30, 40]},
            "ints64_1d": {"t": "array", "dtype": "int64", "shape": [3],
                          "data": [1, 2, 3]},
            "list_of_strings": {"t": "strings", "shape": [3],
                                "data": ["mach", "alpha", "beta"]},
            "nest": {"t": "dict", "v": {
                "deeper": {"t": "dict", "v": {
                    "depth": {"t": "i64", "v": 2},
                    "repr": {"t": "str", "v": "not the callable repr"},
                    "type": {"t": "str", "v": "not the callable type"}}},
                "depth": {"t": "i64", "v": 1},
                "values": {"t": "array", "dtype": "float64", "shape": [2],
                           "data": [f64(0.5), f64(1.5)]}}},
            "nonfinite": {"t": "array", "dtype": "float64", "shape": [4],
                          "data": ["nan", "inf", "-inf", f64(0.0)]},
        },
    }
    with open(ref_path, "w") as fh:
        json.dump(reference, fh, sort_keys=True, separators=(",", ":"))
    return out


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])
    print("wrote %s" % sys.argv[1])
