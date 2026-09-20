"""Phase 3 verification driver for the Python implementation.

Also runs a batch of jobs from one JSON file, so that a language with
a slow start-up pays for it once.

Uses the public API of python/README.md only. Every language has one
of these and they all speak the same JSON, so the harness can compare
them without knowing anything about any of them.

  driver.py check   FILE PROBES.json     validator, support ids, probes
  driver.py write   IN.mes OUT.mes       read and write again
  driver.py eval    FILE SPEC.json       evaluate and probe the result
  driver.py evalw   FILE SPEC.json OUT   evaluate and write the result
  driver.py codec   FILE                 every callable dict, tagged
"""

from __future__ import annotations

import json
import os
import struct
import sys

import numpy as np

# Pin the package to this worktree. The conda environment is shared
# with other worktrees and its editable install is repointed whenever
# one of them installs, so importing by name alone is not safe here.
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "python"))

import mestra

AXES = ("row", "instance", "draw", "node", "component", "index")
ALL_AXES = AXES + ("cell", "cell_plus_one")


def fmt(value):
    arr = np.asarray(value)
    if arr.dtype.kind == "f":
        return "%.17e" % float(arr)
    if arr.dtype.kind == "b":
        return str(int(arr))
    if arr.dtype.kind in "SUO":
        return arr.item().decode() if isinstance(arr.item(), bytes) else str(arr.item())
    return str(int(arr))


def slot_array(ds, path):
    parts = path.strip("/").split("/")
    if parts[0] == "keys":
        return ds.keys[parts[1]].values, ("row",)
    if parts[0] == "scalars":
        return ds.scalars[parts[1]].values, ("row",)
    if parts[0] == "row_support":
        return np.asarray(ds.row_support), ("row",)
    if parts[0] == "categories":
        return np.asarray(ds.categories[parts[1]]), ("category",)
    if parts[0] == "supports":
        s = ds.supports[parts[1]]
        if parts[2] == "coordinates":
            return s.coordinates.values, None
        if parts[2] == "cell_types":
            return np.asarray(s.cell_types), ("cell",)
        if parts[2] == "cell_offsets":
            return np.asarray(s.cell_offsets), ("cell_plus_one",)
        if parts[2] == "cell_connectivity":
            return np.asarray(s.cell_connectivity), ("index",)
        table = s.node_arrays if parts[2] == "node_arrays" else s.cell_arrays
        return table[parts[3]].values, None
    if parts[0] == "callables":
        value = ds.callables[parts[1]].to_dict()
        for part in parts[2:]:
            value = value[part]
        return np.asarray(value), "dict"
    raise KeyError(path)


def probe(ds, p):
    array, dims = slot_array(ds, p["slot"])
    where = {n: p[n] for n in ALL_AXES if n in p}
    if dims == "dict":
        # Section 30: a dictionary dataset has no logical dimension
        # names; the index fields apply in a fixed order, in file order.
        idx = tuple(where[n] for n in AXES if n in where)
        return fmt(array[idx])
    if dims is not None:
        idx = tuple(where[n] for n in dims if n in where)
        return fmt(np.asarray(array)[idx])
    if "node" in where and "node" not in array.dims:
        where["cell"] = where.pop("node")
    return fmt(array.at(**where))


def do_check(path, probes_path):
    out = {"errors": [], "warnings": [], "support_ids": {}, "probes": [],
           "trouble": []}
    try:
        report = mestra.validate(path)
        out["errors"] = list(report.error_ids)
        out["warnings"] = list(report.warning_ids)
    except Exception as exc:
        out["trouble"].append("validate: %s: %s" % (type(exc).__name__, exc))
    try:
        out["support_ids"] = dict(mestra.support_ids(path))
    except Exception as exc:
        out["trouble"].append("support_ids: %s: %s" % (type(exc).__name__, exc))
    probes = json.load(open(probes_path))
    try:
        with mestra.read(path) as ds:
            for p in probes:
                try:
                    out["probes"].append(probe(ds, p))
                except Exception as exc:
                    out["probes"].append(None)
                    out["trouble"].append(
                        "probe %s: %s: %s" % (p["slot"], type(exc).__name__, exc))
    except Exception as exc:
        out["trouble"].append("read: %s: %s" % (type(exc).__name__, exc))
        while len(out["probes"]) < len(probes):
            out["probes"].append(None)
    return out


def do_write(src, dst):
    ds = mestra.read(src, lazy=False)
    mestra.write(ds, dst)
    return {"ok": True}


def table_of(spec):
    return {k: np.array([float(struct.unpack(">d", bytes.fromhex(
        "%016x" % struct.unpack(">Q", struct.pack(">d", float(v)))[0]))[0])
        for v in vs]) for k, vs in spec["keys"].items()}


def do_eval(path, spec_path, out_path=None):
    spec = json.load(open(spec_path))
    table = {k: np.array([float(v) for v in vs])
             for k, vs in spec["keys"].items()}
    out = {"probes": [], "trouble": []}
    with mestra.read(path) as ds:
        got = mestra.evaluate(ds, table)
        for p in spec["probes"]:
            try:
                out["probes"].append(probe(got, p))
            except Exception as exc:
                out["probes"].append(None)
                out["trouble"].append("%s: %s" % (p["slot"], exc))
        if out_path:
            mestra.write(got, out_path)
    return out


def tagged(value):
    if value is None:
        return {"t": "null"}
    if isinstance(value, dict):
        return {"t": "dict", "v": {k: tagged(v) for k, v in value.items()}}
    if isinstance(value, (bool, np.bool_)) and not isinstance(value, np.ndarray):
        return {"t": "bool", "v": bool(value)}
    if isinstance(value, np.ndarray):
        if value.ndim == 0:
            return tagged(value.item())
        if value.dtype.kind in "USO":
            return {"t": "strings", "shape": list(value.shape),
                    "data": [v.decode() if isinstance(v, bytes) else str(v)
                             for v in value.reshape(-1)]}
        if value.dtype == np.bool_ or value.dtype == np.int8:
            return {"t": "array", "dtype": "bool", "shape": list(value.shape),
                    "data": [bool(v) for v in value.reshape(-1)]}
        if value.dtype == np.int32:
            return {"t": "array", "dtype": "int32", "shape": list(value.shape),
                    "data": [int(v) for v in value.reshape(-1)]}
        if value.dtype.kind == "i":
            return {"t": "array", "dtype": "int64", "shape": list(value.shape),
                    "data": [int(v) for v in value.reshape(-1)]}
        return {"t": "array", "dtype": "float64", "shape": list(value.shape),
                "data": ["%.17e" % float(v) for v in value.reshape(-1)]}
    if isinstance(value, (str, bytes)):
        return {"t": "str",
                "v": value.decode() if isinstance(value, bytes) else value}
    if isinstance(value, (int, np.integer)):
        return {"t": "i64", "v": int(value)}
    if isinstance(value, (float, np.floating)):
        return {"t": "f64", "v": "%.17e" % float(value)}
    if isinstance(value, (list, tuple)):
        # This reader hands back a Python list for a fixed-length
        # string dataset and a numpy array for a numeric one, so a
        # list is a string list even when it is empty.
        if all(isinstance(v, (str, bytes)) for v in value):
            return {"t": "strings", "shape": [len(value)],
                    "data": [v.decode() if isinstance(v, bytes) else v
                             for v in value]}
        return tagged(np.asarray(value))
    return {"t": "?", "v": repr(value)}


def do_codec(path):
    out = {}
    with mestra.read(path) as ds:
        for name, c in ds.callables.items():
            out[name] = {"type": getattr(c, "type", None),
                         "dict": tagged(c.to_dict())}
    return out


def run_job(job):
    op = job["op"]
    if op == "check":
        return do_check(job["file"], job["probes"])
    if op == "write":
        return do_write(job["src"], job["dst"])
    if op == "eval":
        return do_eval(job["file"], job["spec"])
    if op == "evalw":
        return do_eval(job["file"], job["spec"], job["mes"])
    if op == "codec":
        return do_codec(job["file"])
    raise ValueError("unknown op %s" % op)


def do_batch(jobs_path):
    jobs = json.load(open(jobs_path))
    done = 0
    for job in jobs:
        try:
            result = run_job(job)
        except Exception as exc:
            result = {"failed": "%s: %s" % (type(exc).__name__, exc)}
        with open(job["out"], "w") as fh:
            json.dump(result, fh)
        done += 1
    return {"jobs": done}


def main(argv):
    mode = argv[1]
    if mode == "batch":
        result = do_batch(argv[2])
    elif mode == "check":
        result = do_check(argv[2], argv[3])
    elif mode == "write":
        result = do_write(argv[2], argv[3])
    elif mode == "eval":
        result = do_eval(argv[2], argv[3])
    elif mode == "evalw":
        result = do_eval(argv[2], argv[3], argv[4])
    elif mode == "codec":
        result = do_codec(argv[2])
    else:
        raise SystemExit("unknown mode %s" % mode)
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
